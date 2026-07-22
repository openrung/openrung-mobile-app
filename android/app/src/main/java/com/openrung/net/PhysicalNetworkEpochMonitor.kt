package com.openrung.net

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The physical-network identity relevant to a long-lived WSS socket. A route, DNS, interface, or
 * transport change starts a new epoch even when Android keeps the same [Network] handle.
 */
internal data class PhysicalNetworkFingerprint(
    val handle: Long,
    val transports: List<Int>,
    val validated: Boolean,
    val metered: Boolean,
    val interfaceName: String,
    val linkAddresses: List<String>,
    val dnsServers: List<String>,
    val routes: List<String>,
)

/** Pure, synchronized change detector kept separate so network-recovery semantics are JVM-tested. */
internal class NetworkEpochTracker<T>(initial: Set<T>) {
    private var current = initial.toSet()

    @Synchronized
    fun update(next: Set<T>): Boolean {
        val snapshot = next.toSet()
        if (snapshot == current) return false
        current = snapshot
        return true
    }
}

/**
 * Watches only non-VPN networks with Internet capability. The first callbacks produced by Android
 * after registration are absorbed by the baseline snapshot; [onChanged] runs only for a later
 * epoch. Closing is idempotent and prevents callbacks from escaping the owning WSS session.
 */
internal class PhysicalNetworkEpochMonitor(
    context: Context,
    private val onChanged: () -> Unit,
) : AutoCloseable {
    private val connectivity = context.getSystemService(ConnectivityManager::class.java)
    private val closed = AtomicBoolean(false)
    private val tracker = NetworkEpochTracker(snapshot())

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = inspectEpoch()

        override fun onLost(network: Network) = inspectEpoch()

        override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) =
            inspectEpoch()

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) =
            inspectEpoch()
    }

    init {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        connectivity.registerNetworkCallback(request, callback)
        // Close the race between taking the baseline and registering the callback. If Android has
        // not delivered its initial callback yet, this explicit comparison still observes a switch.
        inspectEpoch()
    }

    private fun inspectEpoch() {
        if (closed.get()) return
        if (tracker.update(snapshot()) && !closed.get()) onChanged()
    }

    private fun snapshot(): Set<PhysicalNetworkFingerprint> =
        connectivity.allNetworks.mapNotNullTo(linkedSetOf()) { network ->
            val capabilities = connectivity.getNetworkCapabilities(network) ?: return@mapNotNullTo null
            if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) ||
                !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            ) {
                return@mapNotNullTo null
            }
            val links = connectivity.getLinkProperties(network)
            PhysicalNetworkFingerprint(
                handle = network.networkHandle,
                transports = KNOWN_TRANSPORTS.filter(capabilities::hasTransport),
                validated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                metered = !capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED),
                interfaceName = links?.interfaceName.orEmpty(),
                linkAddresses = links?.linkAddresses.orEmpty().map { it.toString() }.sorted(),
                dnsServers = links?.dnsServers.orEmpty().map { it.hostAddress.orEmpty() }.sorted(),
                routes = links?.routes.orEmpty().map { it.toString() }.sorted(),
            )
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { connectivity.unregisterNetworkCallback(callback) }
    }

    private companion object {
        val KNOWN_TRANSPORTS = listOf(
            NetworkCapabilities.TRANSPORT_CELLULAR,
            NetworkCapabilities.TRANSPORT_WIFI,
            NetworkCapabilities.TRANSPORT_BLUETOOTH,
            NetworkCapabilities.TRANSPORT_ETHERNET,
            NetworkCapabilities.TRANSPORT_VPN,
            NetworkCapabilities.TRANSPORT_WIFI_AWARE,
            NetworkCapabilities.TRANSPORT_LOWPAN,
            NetworkCapabilities.TRANSPORT_USB,
        )
    }
}
