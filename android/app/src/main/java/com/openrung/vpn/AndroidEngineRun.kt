package com.openrung.vpn

import android.net.*
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import com.openrung.net.*
import com.openrung.telemetry.RunApplicationConnections
import io.nekohasekai.libbox.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean

/** A native TUN owner created once per Go runtime attempt; never rebound to a successor. */
internal class AndroidEngineRun(
    private val service: OpenRungVpnService,
    private val telemetry: OpenRungRunTelemetry,
    private val retired: (AndroidEngineRun) -> Unit,
) : OpenRungMobileRun {
    private val cm = service.getSystemService(ConnectivityManager::class.java)
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private var fd: ParcelFileDescriptor? = null
    @Volatile private var interfaceName = ""
    @Volatile private var network: Network? = null
    private val counts = RunApplicationConnections(service.packageName, SystemClock::elapsedRealtime) { name, uid, count ->
        telemetry.recordApplicationConnections(name, uid, count)
    }
    private val platform = OpenRungLibboxPlatform(service, { descriptor, name ->
        synchronized(lock) {
            check(!closed.get()) { "TUN owner is closed" }
            check(fd == null) { "TUN owner already has a descriptor" }
            fd = descriptor; interfaceName = name
        }
    }, counts::record)
    override fun platform(): PlatformInterface = platform
    fun refreshInterfaces() = platform.refreshInterfaces()

    private fun ownedNetwork(): Network? = network?.takeIf { n ->
        !closed.get() && cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true &&
            cm.getLinkProperties(n)?.interfaceName == interfaceName
    }

    override fun waitReady(operation: OpenRungEngineOperation) = operation(operation) {
        while (true) {
            ensureActive()
            if (closed.get()) throw IOException("TUN owner is closed")
            val name = interfaceName
            if (name.isNotEmpty()) {
                val published = cm.allNetworks.firstOrNull { n ->
                    cm.getNetworkCapabilities(n)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true &&
                        cm.getLinkProperties(n)?.let { links ->
                            links.interfaceName == name && links.linkAddresses.isNotEmpty() &&
                                links.routes.isNotEmpty() && links.dnsServers.isNotEmpty()
                        } == true
                }
                if (published != null) { network = published; return@operation }
            }
            delay(25)
        }
    }

    override fun verifyPath(operation: OpenRungEngineOperation, phase: String?): String {
        return try {
            operation(operation) {
                val dns = DnsProbe(VpnNetworkDnsTransport(service, ::ownedNetwork))
                val http = InternetProbe(::ownedNetwork)
                val probe = TunnelPathProbe(dns, http)
                if (phase == "startup") probe.verify() else probe.verifyOnce()
                check(ownedNetwork() != null) { "Run's VPN Network disappeared" }
            }
            """{"path":"android_vpn_network","fresh_dns":true,"pinned_https":true}"""
        } catch (error: Exception) {
            buildJsonObject {
                put("error", error.message ?: "VPN path verification failed")
                if (!operation.isCancelled && ownedNetwork() != null && error !is CancellationException && isGenuineRemoteDataPathFailure(error)) {
                    put("remote_stage", if (error is DnsPathUnverifiedException) "dns_probe" else "internet_probe")
                }
            }.toString()
        }
    }

    private fun <T> operation(token: OpenRungEngineOperation, work: suspend CoroutineScope.() -> T): T = runBlocking {
        val task = async(Dispatchers.IO, block = work)
        val watcher = launch {
            while (isActive) {
                if (token.isCancelled || closed.get()) { task.cancel(); break }
                delay(20)
            }
        }
        try { task.await() } finally { watcher.cancelAndJoin() }
    }

    override fun close() {
        synchronized(lock) {
            if (!closed.compareAndSet(false, true)) return
            counts.close()
            fd?.close(); fd = null; network = null
        }
        retired(this)
    }
}
