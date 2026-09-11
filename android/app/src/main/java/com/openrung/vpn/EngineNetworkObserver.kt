package com.openrung.vpn

import android.content.Context
import android.net.*
import android.os.Build
import android.os.Handler
import android.os.Looper
import kotlinx.serialization.json.*

internal data class EngineNetworkSnapshot(
    val up: Boolean,
    val fingerprint: String,
    val dnsJSON: String,
    val attributes: Map<String, String>,
    val defaultNetwork: Network? = null,
)

/** Observe Android's best physical network, even while activeNetwork is our VPN. */
internal class EngineNetworkObserver(context: Context, private val changed: (EngineNetworkSnapshot) -> Unit) : AutoCloseable {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private var closed = false
    private var selected: Network? = null
    private var capabilities: NetworkCapabilities? = null
    private var properties: LinkProperties? = null
    @Volatile var current = snapshot(context)
        private set

    // All callback data is supplied by Android. Do not query ConnectivityManager
    // here: its synchronous view may lag the callback, and telemetry reads this cache.
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = synchronized(this@EngineNetworkObserver) {
            if (!closed && selected != network) {
                selected = network; capabilities = null; properties = null
            }
        }
        override fun onLost(network: Network) = synchronized(this@EngineNetworkObserver) {
            if (selected == network) {
                selected = null; capabilities = null; properties = null
                publish(buildSnapshot(null, null, null))
            }
        }
        override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) = synchronized(this@EngineNetworkObserver) {
            if (selected == network) { capabilities = NetworkCapabilities(caps); update() }
        }
        override fun onLinkPropertiesChanged(network: Network, links: LinkProperties) = synchronized(this@EngineNetworkObserver) {
            if (selected == network) { properties = links; update() }
        }
    }
    init {
        val request = NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
        val handler = Handler(Looper.getMainLooper())
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            connectivity.registerBestMatchingNetworkCallback(request, callback, handler)
        } else {
            // API 26–30 has no passive best-match subscription. A request uses the
            // system's same network ranking and is released with this owner.
            connectivity.requestNetwork(request, callback, handler)
        }
    }
    private fun update() {
        if (capabilities != null && properties != null) publish(buildSnapshot(selected, capabilities, properties))
    }
    private fun publish(next: EngineNetworkSnapshot) {
        if (closed || next == current) return
        current = next
        changed(next)
    }
    @Synchronized override fun close() {
        if (!closed) { closed = true; connectivity.unregisterNetworkCallback(callback) }
    }
    companion object {
        /** Pre-TUN seed only; never fall back to allNetworks iteration order. */
        fun snapshot(context: Context): EngineNetworkSnapshot {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val network = cm.activeNetwork
            val caps = network?.let(cm::getNetworkCapabilities)
            return buildSnapshot(network, caps, network?.let(cm::getLinkProperties))
        }
        private fun buildSnapshot(network: Network?, caps: NetworkCapabilities?, links: LinkProperties?): EngineNetworkSnapshot {
            val physical = network?.takeIf {
                caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == false &&
                    caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            }
            val activeCaps = caps?.takeIf { physical != null }
            val dns = if (physical == null) emptyList() else links?.dnsServers.orEmpty()
                .mapNotNull { it.hostAddress?.substringBefore('%') }.distinct().sorted()
            val fingerprint = if (physical == null) "" else listOf(
                physical.networkHandle, (0..8).filter { caps?.hasTransport(it) == true },
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING),
                links?.interfaceName, links?.linkAddresses?.map { it.toString() }?.sorted(),
                links?.routes?.map { it.toString() }?.sorted(), dns,
            ).joinToString("|")
            val transport = when {
                activeCaps == null -> "unknown"
                activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                activeCaps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
            return EngineNetworkSnapshot(physical != null, fingerprint, buildJsonArray { dns.forEach { add(it) } }.toString(), mapOf(
                "network_transport" to transport,
                "network_metered" to (activeCaps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true).toString(),
                "network_roaming" to (activeCaps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING) != true).toString(),
            ), physical)
        }
    }
}
