package com.openrung.vpn

import android.net.VpnService
import android.util.Log
import com.openrung.BuildConfig
import com.openrung.model.RelayDescriptor
import com.openrung.state.OpenRungStatusStore
import com.openrung.telemetry.TelemetryManager
import io.nekohasekai.libbox.CommandClient
import io.nekohasekai.libbox.CommandClientHandler
import io.nekohasekai.libbox.CommandClientOptions
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.ConnectionEvents
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.LogIterator
import io.nekohasekai.libbox.OutboundGroupItemIterator
import io.nekohasekai.libbox.OutboundGroupIterator
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.StatusMessage
import io.nekohasekai.libbox.StringIterator
import io.nekohasekai.libbox.SystemProxyStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

interface ProxyEngine {
    suspend fun start(
        relay: RelayDescriptor,
        configJson: String,
        vpnService: VpnService,
    )

    /** Completes only when the local tunnel engine stops without an explicit service teardown. */
    suspend fun awaitUnexpectedStop(): String = awaitCancellation()

    /** Persistent companion to [awaitUnexpectedStop] for resolving simultaneous path/engine events. */
    fun unexpectedStopReason(): String? = null

    fun stop()
}

object ProxyEngineFactory {
    // NOTE: this source file compiles directly against the libbox AAR
    // (android/app/libs/libbox.aar, added conditionally in app/build.gradle). A checkout
    // without the AAR cannot compile this file; the stub below only guards the runtime
    // case of the libbox classes being absent (e.g. a build variant that stripped the AAR).
    private val libboxLinked: Boolean = try {
        Libbox::class.java.name
        true
    } catch (error: Throwable) {
        false
    }

    fun create(): ProxyEngine = if (libboxLinked) LibboxProxyEngine() else StubProxyEngine()

    fun isAvailable(): Boolean = libboxLinked

    /**
     * Parses and constructs the sing-box graph without starting a service, opening a TUN, or
     * dialing the network. This must run before relay reachability so deterministic local config
     * failures cannot be mistaken for a blocked direct path and authorize a WSS ticket.
     */
    fun preflight(configJson: String) {
        check(libboxLinked) { "libbox engine not linked" }
        Libbox.checkConfig(configJson)
    }
}

/** Fallback engine used when the libbox classes are unavailable at runtime. */
class StubProxyEngine : ProxyEngine {
    override suspend fun start(
        relay: RelayDescriptor,
        configJson: String,
        vpnService: VpnService,
    ) {
        throw IllegalStateException("libbox engine not linked")
    }

    override fun stop() = Unit
}

class LibboxProxyEngine : ProxyEngine {
    private val resources = StopSafeResourceRegistry(EngineResource.entries.toList())
    private val unexpectedStop = CompletableDeferred<String>()
    private val unexpectedReason = AtomicReference<String?>(null)

    override suspend fun start(
        relay: RelayDescriptor,
        configJson: String,
        vpnService: VpnService,
    ) {
        ensureRunning()
        val platform = OpenRungLibboxPlatform(vpnService) { fd ->
            resources.replace(EngineResource.TUN) { fd.close() }
        }
        val handler = OpenRungCommandServerHandler(::onServiceStop)
        val options = SetupOptions().apply {
            basePath = File(vpnService.filesDir, "libbox").apply { mkdirs() }.path
            workingPath = File(vpnService.getExternalFilesDir(null) ?: vpnService.filesDir, "libbox").apply { mkdirs() }.path
            tempPath = File(vpnService.cacheDir, "libbox").apply { mkdirs() }.path
            // The in-memory log ring is only read by debug tooling; keep it small in release,
            // where debug mode would also forward every libbox line into the status store.
            logMaxLines = if (BuildConfig.DEBUG) 3000 else 300
            debug = BuildConfig.DEBUG
            crashReportSource = "OpenRungAndroid"
            oomKillerEnabled = false
            oomKillerDisabled = true
        }

        Libbox.setup(options)
        Libbox.checkConfig(configJson)

        val server = CommandServer(handler, platform)
        server.start()
        if (!resources.replace(EngineResource.SERVER) {
                runCatching { server.closeService() }
                runCatching { server.close() }
            }
        ) {
            ensureRunning()
        }
        server.startOrReloadService(configJson, OverrideOptions())
        connectStatusClient()?.let { client ->
            resources.replace(EngineResource.STATUS) { client.disconnect() }
        }
        ensureRunning()
    }

    /**
     * Subscribes to the in-process libbox status stream, whose messages carry the tunnel's
     * cumulative uplink/downlink byte counters (enabled by the clash_api traffic accounting in
     * the sing-box config). Best-effort: if the subscription fails, sessions simply omit the
     * bytes_sent/bytes_received telemetry measurements.
     */
    private fun connectStatusClient(): CommandClient? {
        val options = CommandClientOptions().apply {
            addCommand(Libbox.CommandStatus)
            statusInterval = STATUS_INTERVAL_NS
        }
        val client = CommandClient(TrafficStatusHandler(), options)
        return runCatching { client.connect() }
            .map { client }
            .onFailure { Log.w(LOG_TAG, "libbox status client connect failed", it) }
            .getOrNull()
    }

    override suspend fun awaitUnexpectedStop(): String = unexpectedStop.await()

    override fun unexpectedStopReason(): String? = unexpectedReason.get()

    private fun onServiceStop() {
        resources.stop(waitForOngoing = false) {
            val reason = "libbox tunnel engine stopped unexpectedly"
            unexpectedReason.compareAndSet(null, reason)
            unexpectedStop.complete(reason)
        }
    }

    override fun stop() {
        captureFinalTrafficSnapshot()
        // Deliberately drain on every call. If stop wins while start is still inside a native call,
        // any resource published afterward is rejected and closed instead of surviving a one-shot
        // compare-and-set that already returned.
        resources.stop()
    }

    /**
     * The status stream pushes counters only every [STATUS_INTERVAL_NS], so at teardown the
     * cached totals can be up to a minute stale — a short session would report none of its
     * post-initial traffic. The command server sends a status message immediately on subscribe,
     * so a throwaway client grabs one final snapshot before the engine goes down. Best-effort
     * and bounded: a dead or wedged server just fails the connect or times the latch out.
     */
    private fun captureFinalTrafficSnapshot() {
        if (resources.isStopped()) return
        runCatching {
            val received = CountDownLatch(1)
            val options = CommandClientOptions().apply {
                addCommand(Libbox.CommandStatus)
                statusInterval = STATUS_INTERVAL_NS
            }
            val client = CommandClient(TrafficStatusHandler { received.countDown() }, options)
            runCatching { client.connect() }.onSuccess {
                received.await(FINAL_STATUS_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                runCatching { client.disconnect() }
            }
        }
    }

    private suspend fun ensureRunning() {
        currentCoroutineContext().ensureActive()
        check(!resources.isStopped()) { "libbox tunnel engine stopped during startup" }
    }

    private enum class EngineResource {
        STATUS,
        SERVER,
        TUN,
    }

    companion object {
        /**
         * Status push interval, a Go time.Duration in nanoseconds. The counters it carries are
         * cumulative and only sampled by the telemetry heartbeat (every 50–70 s), so a coarse
         * interval loses no data while avoiding a loopback-gRPC wakeup every few seconds.
         */
        private const val STATUS_INTERVAL_NS = 60_000_000_000L

        /** Upper bound on waiting for the teardown snapshot's immediate status push. */
        private const val FINAL_STATUS_TIMEOUT_MS = 700L
    }
}

/**
 * Thread-safe resource publication for a start/stop race. Once stopped, a late resource is closed
 * immediately; repeated stop calls also drain anything that raced with an earlier drain. The first
 * stop callback is lock-linearized so an intentional stop cannot be reported as unexpected.
 */
internal class StopSafeResourceRegistry<K>(
    private val closeOrder: List<K>,
) {
    private val lock = Any()
    private val resources = LinkedHashMap<K, () -> Unit>()
    private var stopped = false
    private var closeCompletion: CountDownLatch? = null

    fun replace(key: K, close: () -> Unit): Boolean {
        var previous: (() -> Unit)? = null
        val accepted = synchronized(lock) {
            previous = resources.remove(key)
            if (stopped) {
                false
            } else {
                resources[key] = close
                true
            }
        }
        previous?.let(::closeQuietly)
        if (!accepted) closeQuietly(close)
        return accepted
    }

    fun stop(
        waitForOngoing: Boolean = true,
        onFirstStop: () -> Unit = {},
    ): Boolean {
        val ongoingClose: CountDownLatch?
        val firstStop: Boolean
        val closeActions: List<() -> Unit>
        synchronized(lock) {
            ongoingClose = closeCompletion
            if (ongoingClose == null) {
                firstStop = !stopped
                stopped = true
                closeActions = buildList {
                    closeOrder.forEach { key -> resources.remove(key)?.let(::add) }
                    addAll(resources.values)
                }
                resources.clear()
                closeCompletion = CountDownLatch(1)
            } else {
                firstStop = false
                closeActions = emptyList()
            }
        }

        if (ongoingClose != null) {
            if (waitForOngoing) {
                awaitUninterruptibly(ongoingClose)
            }
            return false
        }

        try {
            // A concurrent lifecycle stop waits above, so it cannot return and close WSS while
            // another thread is still closing the engine. Native serviceStop callbacks opt out of
            // waiting to avoid re-entrant closeService callback deadlocks.
            closeActions.forEach(::closeQuietly)
            // Publish an unexpected stop only after engine resources have actually retired.
            if (firstStop) onFirstStop()
            return firstStop
        } finally {
            val completed = synchronized(lock) {
                closeCompletion.also { closeCompletion = null }
            }
            completed?.countDown()
        }
    }

    fun isStopped(): Boolean = synchronized(lock) { stopped }

    private fun closeQuietly(close: () -> Unit) {
        runCatching(close)
    }

    private fun awaitUninterruptibly(completion: CountDownLatch) {
        var interrupted = false
        while (completion.count > 0) {
            try {
                completion.await()
            } catch (_: InterruptedException) {
                interrupted = true
            }
        }
        if (interrupted) Thread.currentThread().interrupt()
    }
}

/** Receives libbox status pushes and forwards the tunnel's traffic counters to telemetry. */
private class TrafficStatusHandler(
    private val onStatus: (() -> Unit)? = null,
) : CommandClientHandler {
    override fun connected() = Unit

    override fun disconnected(message: String?) = Unit

    override fun clearLogs() = Unit

    override fun initializeClashMode(modeList: StringIterator?, currentMode: String?) = Unit

    override fun setDefaultLogLevel(level: Int) = Unit

    override fun updateClashMode(newMode: String?) = Unit

    override fun writeConnectionEvents(events: ConnectionEvents?) = Unit

    override fun writeGroups(groups: OutboundGroupIterator?) = Unit

    override fun writeLogs(messages: LogIterator?) = Unit

    override fun writeOutbounds(outbounds: OutboundGroupItemIterator?) = Unit

    override fun writeStatus(message: StatusMessage?) {
        val status = message ?: return
        if (!status.trafficAvailable) return
        TelemetryManager.updateTrafficCounters(
            bytesSent = status.uplinkTotal,
            bytesReceived = status.downlinkTotal,
        )
        onStatus?.invoke()
    }
}

private class OpenRungCommandServerHandler(
    private val stopEngine: () -> Unit,
) : CommandServerHandler {
    override fun connectSSHAgent(): Int = -1

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply {
            available = false
            enabled = false
        }

    override fun serviceReload() = Unit

    override fun serviceStop() {
        stopEngine()
    }

    override fun setSystemProxyEnabled(isEnabled: Boolean) = Unit

    override fun triggerNativeCrash() = Unit

    override fun writeDebugMessage(message: String?) {
        message
            ?.lineSequence()
            ?.map { it.trim() }
            ?.filter { it.isNotBlank() }
            ?.forEach {
                Log.d(LOG_TAG, it)
                // Each appended line persists the status snapshot and fans out to the JS bridge;
                // only debug builds surface libbox internals in the on-screen console.
                if (BuildConfig.DEBUG) {
                    OpenRungStatusStore.appendLog("libbox: $it")
                }
            }
    }
}

private const val LOG_TAG = "OpenRungLibbox"
