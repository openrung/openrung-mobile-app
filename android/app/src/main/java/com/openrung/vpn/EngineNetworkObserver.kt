package com.openrung.vpn

import android.content.Context
import android.net.*
import kotlinx.serialization.json.*
import java.util.concurrent.atomic.AtomicBoolean

internal data class EngineNetworkSnapshot(val up: Boolean, val fingerprint: String, val dnsJSON: String, val attributes: Map<String,String>)

/** Physical network observation only; epochs and recovery decisions belong to connectcore. */
internal class EngineNetworkObserver(private val context: Context, private val changed: (EngineNetworkSnapshot) -> Unit) : AutoCloseable {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val closed = AtomicBoolean(false)
    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = update()
        override fun onLost(network: Network) = update()
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = update()
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = update()
    }
    init {
        connectivity.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), callback)
        update()
    }
    private fun update() { if (!closed.get()) changed(snapshot(context)) }
    override fun close() { if (closed.compareAndSet(false,true)) connectivity.unregisterNetworkCallback(callback) }
    companion object {
        fun snapshot(context: Context): EngineNetworkSnapshot {
            val cm = context.getSystemService(ConnectivityManager::class.java)
            val networks = cm.allNetworks.filter { network -> cm.getNetworkCapabilities(network)?.let {
                !it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            } == true }.sortedBy { it.networkHandle }
            val dns = networks.flatMap { cm.getLinkProperties(it)?.dnsServers.orEmpty() }.mapNotNull { it.hostAddress?.substringBefore('%') }.distinct().sorted()
            val fingerprint = networks.joinToString(";") { network ->
                val links = cm.getLinkProperties(network)
                val caps = cm.getNetworkCapabilities(network)
                listOf(network.networkHandle, (0..8).filter { caps?.hasTransport(it) == true },
                    caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED), caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                    links?.interfaceName, links?.linkAddresses?.map { it.toString() }?.sorted(), links?.routes?.map { it.toString() }?.sorted(),
                    links?.dnsServers?.map { it.hostAddress }?.sortedBy { it.orEmpty() }).joinToString("|")
            }
            val caps = networks.firstOrNull()?.let(cm::getNetworkCapabilities)
            val transport = when {
                caps == null -> "unknown"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "other"
            }
            return EngineNetworkSnapshot(networks.isNotEmpty(), fingerprint, buildJsonArray { dns.forEach { add(it) } }.toString(), mapOf(
                "network_transport" to transport, "network_metered" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true).toString(),
                "network_roaming" to (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING) != true).toString()))
        }
    }
}
