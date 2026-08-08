package com.openrung.net

import java.util.concurrent.atomic.AtomicInteger

/**
 * App-level DNS resolver failover. sing-box has no upstream failover of its own — `dns.final`
 * names exactly one server — so the service rotates which DoH resolver is emitted first
 * (`dns-0`, the final/default resolver) whenever a fresh-DNS probe shows the current primary
 * cannot answer through the tunnel. Every [SingBoxConfiguration] built afterwards, including
 * same-relay retries, WSS-ladder attempts, and recovery reconnects, picks up the rotated order.
 */
class DnsResolverRotation(
    private val resolvers: List<String> = DEFAULT_RESOLVERS,
) {
    init {
        require(resolvers.isNotEmpty()) { "at least one DNS resolver is required" }
    }

    private val offset = AtomicInteger(0)

    val resolverCount: Int get() = resolvers.size

    /** Resolver IPs in emission order; index 0 becomes the `dns-0` final resolver. */
    fun currentServers(): List<String> {
        val shift = Math.floorMod(offset.get(), resolvers.size)
        return List(resolvers.size) { index -> resolvers[(index + shift) % resolvers.size] }
    }

    /**
     * Advances the rotation only when [failedServers] is still the current order, so repeated
     * reports of the same dead primary (startup retry + health-loop strikes) advance exactly
     * once and a stale report can never skip past a resolver that has not been tried. Returns
     * true when this call performed the advance.
     */
    fun noteDnsPathFailure(failedServers: List<String>): Boolean {
        val observed = offset.get()
        val shift = Math.floorMod(observed, resolvers.size)
        val current = List(resolvers.size) { index -> resolvers[(index + shift) % resolvers.size] }
        return current == failedServers && offset.compareAndSet(observed, observed + 1)
    }

    companion object {
        /** DoH-capable public resolvers reached as IP literals: no bootstrap resolution needed. */
        val DEFAULT_RESOLVERS = listOf("1.1.1.1", "8.8.8.8")
    }
}
