package com.openrung.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.net.InetSocketAddress
import java.net.Socket
import javax.net.SocketFactory

/**
 * Concurrent TCP-connect latency probe for exit-relay endpoints (port of FireflyVPN's
 * LatencyTester approach). Results feed the on-demand "test latency" / connect-to-fastest UI.
 *
 * Tunnel bypass: an active VpnService would otherwise route these probes through the tunnel.
 * `VpnService.protect()` needs the live service instance, but a socket created from a specific
 * non-VPN [Network]'s [SocketFactory] bypasses tun routing without it — so we resolve an
 * underlying non-VPN network (the exact TRANSPORT_VPN-skipping filter ProxyEngine uses) and
 * dial through it. That gives accurate direct RTTs whether or not the tunnel is up. When no
 * non-VPN network is available we fall back to default sockets and report viaTunnel = true.
 */
data class LatencyProbeResult(val id: String, val latencyMs: Long?, val reachable: Boolean)

data class LatencyMeasurement(val viaTunnel: Boolean, val results: List<LatencyProbeResult>)

class LatencyProber(private val context: Context) {
    suspend fun measure(
        targets: List<Triple<String, String, Int>>, // (id, host, port)
        timeoutMs: Int,
        concurrency: Int = 8,
    ): LatencyMeasurement = withContext(Dispatchers.IO) {
        val network = directNetwork()
        val socketFactory = network?.socketFactory
        val semaphore = Semaphore(concurrency.coerceIn(1, 32))

        val results = coroutineScope {
            targets.map { (id, host, port) ->
                async {
                    semaphore.withPermit { probe(id, host, port, timeoutMs, socketFactory) }
                }
            }.awaitAll()
        }
        LatencyMeasurement(viaTunnel = socketFactory == null, results = results)
    }

    private fun probe(
        id: String,
        host: String,
        port: Int,
        timeoutMs: Int,
        socketFactory: SocketFactory?,
    ): LatencyProbeResult {
        if (port <= 0 || port > 65_535) {
            return LatencyProbeResult(id, null, false)
        }
        val cleanHost = host.trim().removePrefix("[").substringBefore("]").substringBefore("%")
        val socket = runCatching { socketFactory?.createSocket() ?: Socket() }.getOrNull()
            ?: return LatencyProbeResult(id, null, false)
        return try {
            val startedNs = System.nanoTime()
            socket.connect(InetSocketAddress(cleanHost, port), timeoutMs)
            val elapsedMs = (System.nanoTime() - startedNs) / 1_000_000
            LatencyProbeResult(id, elapsedMs, true)
        } catch (error: Throwable) {
            // Timeout OR refused: for an exit relay a refused port means a dead relay, so
            // (unlike Firefly) both count as unreachable.
            LatencyProbeResult(id, null, false)
        } finally {
            runCatching { socket.close() }
        }
    }

    /** The active non-VPN network (INTERNET-capable), or null when only the tunnel is available. */
    private fun directNetwork(): Network? {
        val connectivityManager = context.getSystemService(ConnectivityManager::class.java) ?: return null
        return runCatching {
            connectivityManager.allNetworks.firstOrNull { network ->
                val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return@firstOrNull false
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            }
        }.onFailure { Log.w("OpenRungLatency", "could not resolve a direct network", it) }
            .getOrNull()
    }
}
