package com.openrung.vpn

import com.openrung.net.DnsResolverRotation

/**
 * Owns the DoH resolver rotation plus the order the RUNNING engine was verified with, and
 * reports a failover exactly once per failed order.
 *
 * Freezing the active order matters: the health loop observes failures from an engine that was
 * started earlier, and a rotation may already have happened (startup retry, another epoch). If
 * failures were reported against the CURRENT order, three health-loop strikes could advance the
 * rotation three times and skip past resolvers that were never tried. Reporting against the
 * frozen order makes [DnsResolverRotation]'s compare-and-advance a no-op for every strike after
 * the first, so the recovery reconnect leads with exactly the next untried resolver.
 */
internal class DnsFailoverReporter(
    private val rotation: DnsResolverRotation = DnsResolverRotation(),
    private val onFailover: (failed: String, next: String) -> Unit,
) {
    /** Resolver order for the next configuration build. */
    fun currentServers(): List<String> = rotation.currentServers()

    val resolverCount: Int get() = rotation.resolverCount

    /** Freezes the order the now-running engine was verified with. */
    fun activate(servers: List<String>) {
        activeServers = servers
    }

    private var activeServers: List<String> = DnsResolverRotation.DEFAULT_RESOLVERS

    /**
     * Reports a DNS-path failure of [servers] (defaults to the frozen active order, which is
     * what the health loop must use). Returns true when the rotation actually advanced, i.e.
     * when this was the first report of that order.
     */
    fun reportFailure(servers: List<String> = activeServers): Boolean {
        if (!rotation.noteDnsPathFailure(servers)) return false
        onFailover(servers.first(), rotation.currentServers().first())
        return true
    }
}
