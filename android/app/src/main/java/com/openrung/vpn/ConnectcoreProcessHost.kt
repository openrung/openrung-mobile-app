package com.openrung.vpn

import android.net.VpnService
import android.os.Build
import com.openrung.R
import com.openrung.BuildConfig
import com.openrung.config.AppConfig
import com.openrung.model.RelayDescriptor
import com.openrung.model.RecentNode
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.telemetry.ClientIdentity
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungEngine
import io.nekohasekai.libbox.OpenRungEngineListener
import io.nekohasekai.libbox.OpenRungMobileHost
import io.nekohasekai.libbox.OpenRungMobileRun
import io.nekohasekai.libbox.OpenRungRunTelemetry
import io.nekohasekai.libbox.OpenRungWSSProtector
import io.nekohasekai.libbox.SetupOptions
import kotlinx.serialization.json.*
import java.io.File
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** One ordered control queue, engine, and persistent outbox for the entire application process. */
internal object ConnectcoreProcessHost : EngineProcessHost()

internal open class EngineProcessHost(
    private val queue: Executor = Executors.newSingleThreadExecutor { runnable -> Thread(runnable, "OpenRungEngine") },
    private val terminateProcess: (OpenRungVpnService) -> Unit = { it.terminateAfterFailedTeardown() },
    private val factory: ((OpenRungVpnService, OpenRungMobileHost, OpenRungEngineListener) -> OpenRungEngine)? = null,
) : OpenRungMobileHost {
    private val events = EngineEventDispatcher(::post) { OpenRungStatusStore.appendLog(it) }
    private var engine: OpenRungEngine? = null
    private var terminating = false
    @Volatile private var owner: OpenRungVpnService? = null
    @Volatile var sessionId: String? = null
        private set
    private var lease = Any()
    private var startId = -1
    private var broker = ""
    private var country = ""
    private var relay = ""

    fun post(work: () -> Unit) { queue.execute(work) }

    fun connect(service: OpenRungVpnService, id: Int, url: String, targetCountry: String?, targetRelay: String?) = post {
        connectOnQueue(service, id, url, targetCountry, targetRelay)
    }

    private fun connectOnQueue(service: OpenRungVpnService, id: Int, url: String, targetCountry: String?, targetRelay: String?) {
        if (terminating) return
        try {
            if (!stopEngine()) { finishOwner(service, id, false); return }
            releaseOwner()
            owner = service
            sessionId = null
            val currentLease = Any().also { lease = it }
            startId = id
            broker = url; country = targetCountry.orEmpty(); relay = targetRelay.orEmpty()
            events.attach { if (lease === currentLease) consume(service, it) }
            if (engine == null) engine = factory?.invoke(service, this, events) ?: createEngine(service)
            service.observe { snapshot -> post {
                if (owner === service && lease === currentLease) {
                    engine!!.networkChanged(snapshot.up, snapshot.fingerprint, snapshot.dnsJSON)
                    service.refreshRunInterfaces()
                }
            } }
            val initial = service.networkSnapshot()
            engine!!.networkChanged(initial.up, initial.fingerprint, initial.dnsJSON)
            engine!!.resume()
            engine!!.start(broker, country, relay)
        } catch (error: Throwable) {
            if (error !is Exception && error !is LinkageError) throw error
            OpenRungStatusStore.fail(error.message ?: "VPN startup failed")
            finishOwner(service, id, stopEngine())
        }
    }

    fun reapply(service: OpenRungVpnService, id: Int) = post {
        if (owner !== service) { service.finish(id); return@post }
        startId = id
        if (OpenRungStatusStore.uiState.value.status == ConnectionStatus.CONNECTED) {
            connectOnQueue(service, id, broker, country, relay)
        }
    }

    fun stop(service: OpenRungVpnService, id: Int) = post { stopOnQueue(service, id) }

    fun destroyed(service: OpenRungVpnService, id: Int) = post {
        // Destruction following terminal failure must preserve its error in RN.
        // A delayed callback from an old service must never stop its successor.
        if (owner === service) stopOnQueue(service, id)
    }

    private fun stopOnQueue(service: OpenRungVpnService, id: Int) {
        if (terminating) return
        if (owner !== service) {
            if (owner == null) OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTED, relayLabel = null, lastError = null)
            service.finish(id)
            return
        }
        events.detach()
        OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTING)
        val complete = stopEngine()
        if (complete) OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTED, relayLabel = null, lastError = null)
        finishOwner(service, id, complete)
    }

    private fun releaseOwner() {
        events.detach()
        owner?.closeObservation()
        owner = null
        sessionId = null
    }

    private fun finishOwner(service: OpenRungVpnService, id: Int, complete: Boolean) {
        releaseOwner()
        service.closeObservation()
        if (complete) {
            service.finish(id)
        } else {
            // libbox may still hold its duplicated TUN fd. Releasing only Kotlin's
            // descriptor cannot restore routing; the OS must reclaim the process.
            terminating = true
            service.reportFailure("VPN teardown failed; restarting the app is required")
            terminateProcess(service)
        }
    }

    private fun stopEngine(): Boolean {
        val current = engine ?: return true
        runCatching { current.stop(5_000) }.onFailure {
            OpenRungStatusStore.appendLog("Engine shutdown: ${it.message}")
        }
        return runCatching { current.teardownComplete() }.getOrElse {
            OpenRungStatusStore.appendLog("Engine teardown status unavailable: ${it.message}")
            false
        }
    }

    private fun createEngine(service: OpenRungVpnService): OpenRungEngine {
        Libbox.setup(SetupOptions().apply {
            basePath = File(service.filesDir, "libbox").apply { mkdirs() }.path
            workingPath = File(service.filesDir, "libbox").path
            tempPath = File(service.cacheDir, "libbox").apply { mkdirs() }.path
            logMaxLines = if (BuildConfig.DEBUG) 3000 else 300
            debug = BuildConfig.DEBUG; crashReportSource = "OpenRungAndroid"
            oomKillerEnabled = false; oomKillerDisabled = true
        })
        val prefs = service.getSharedPreferences("openrung_telemetry", 0)
        val legacy = prefs.getString("outbox", null)
        val config = buildJsonObject {
            put("install_id", ClientIdentity.getOrCreate(service.applicationContext))
            put("app_version", BuildConfig.VERSION_NAME)
            put("platform_version", Build.VERSION.SDK_INT.toString())
            put("telemetry_directory", service.filesDir.absolutePath)
            put("punch_coordinator_cert_sha256_by_host", buildJsonObject {
                AppConfig.PUNCH_COORDINATOR_CERT_SHA256_BY_HOST.forEach { (host, pin) -> put(host, pin) }
            })
            legacy?.let { put("legacy_telemetry_batch", it) }
        }
        val result = Libbox.newOpenRungMobileEngineForAndroid(config.toString(), object : OpenRungWSSProtector {
            override fun protect(fd: Int): Boolean = owner?.protect(fd) == true
        }, this, events)
        // Constructor success proves every importable legacy row was persisted;
        // corrupt rows keep the shipping outbox's discard behavior.
        if (legacy != null) prefs.edit().remove("outbox").commit()
        return result
    }

    override fun settingsJSON(): String {
        val service = checkNotNull(owner) { "No active VPN owner" }
        check(VpnService.prepare(service) == null) { "android: missing VPN permission" }
        return service.settingsJSON()
    }

    override fun attributesJSON(): String = buildJsonObject {
        put("os_name", "android"); put("android_api", Build.VERSION.SDK_INT.toString())
        put("device_manufacturer", Build.MANUFACTURER); put("device_model", Build.MODEL)
        put("locale", Locale.getDefault().toLanguageTag()); put("timezone", TimeZone.getDefault().id)
        owner?.networkAttributes()?.forEach { (key, value) -> put(key, value) }
    }.toString()

    override fun newRun(telemetry: OpenRungRunTelemetry): OpenRungMobileRun =
        checkNotNull(owner) { "No active VPN owner" }.newRun(telemetry)

    private fun consume(service: OpenRungVpnService, event: EngineEvent) {
        if (owner !== service) return
        when (event.kind) {
            "log" -> event.payload.text("Line")?.let(OpenRungStatusStore::appendLog)
            "notice" -> Unit // State/log delivery already represents recovery; no second policy loop.
            "state" -> {
                val p = event.payload
                val status = runCatching { ConnectionStatus.valueOf(p.text("Status")!!.uppercase(Locale.ROOT)) }.getOrNull() ?: return
                val details = p["Details"] as? JsonObject
                sessionId = details?.text("SessionID")?.takeIf(String::isNotEmpty)
                // Legacy RelayLabel can be an operator name or raw relay ID. Only
                // the atomic location field is suitable for the location UI.
                val location = if (status == ConnectionStatus.CONNECTED) {
                    RelayDescriptor.sanitizeDisplayName(details?.text("LocationLabel").orEmpty(), 128)
                        .ifEmpty { service.getString(R.string.relay_location_unknown) }
                } else null
                OpenRungStatusStore.setStatus(status, relayLabel = location,
                    relayName = if (status == ConnectionStatus.CONNECTED) RelayDescriptor.displayName(details?.text("RelayName"), details?.text("RelayID")) else null,
                    relayClass = if (status == ConnectionStatus.CONNECTED) details?.text("RelayClass") else null,
                    lastError = p.text("LastError"))
                if (status == ConnectionStatus.CONNECTED) {
                    (p["Recents"] as? JsonArray)?.firstOrNull()?.let { raw ->
                        val recent = raw.jsonObject
                        // A relay without geo adds no recent; the first row may
                        // still describe the previous connection.
                        if (recent.text("RelayID") != details?.text("RelayID")) return@let
                        OpenRungStatusStore.recordRecent(RecentNode(
                            countryCode = recent.text("CountryCode").orEmpty(), relayId = details?.text("RelayID").orEmpty(),
                            label = location.orEmpty(), relayName = RelayDescriptor.displayName(details?.text("RelayName"), details?.text("RelayID")),
                            latitude = recent["Latitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0,
                            longitude = recent["Longitude"]?.jsonPrimitive?.doubleOrNull ?: 0.0))
                    }
                }
                service.showStatus(status, location)
                if (status == ConnectionStatus.FAILED) finishOwner(service, startId, stopEngine())
            }
        }
    }
}
internal fun JsonObject.text(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
