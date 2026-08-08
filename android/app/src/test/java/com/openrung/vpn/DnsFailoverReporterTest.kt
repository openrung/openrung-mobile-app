package com.openrung.vpn

import com.openrung.net.DnsResolverRotation
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsFailoverReporterTest {
    @Test
    fun `startup failure advances the rotation and reports the pair once`() {
        val reported = mutableListOf<Pair<String, String>>()
        val reporter = reporter(reported)

        assertTrue(reporter.reportFailure(listOf("1.1.1.1", "8.8.8.8")))
        assertEquals(listOf("1.1.1.1" to "8.8.8.8"), reported)
        assertEquals(listOf("8.8.8.8", "1.1.1.1"), reporter.currentServers())

        // The same order reported twice (startup retry racing the health loop) must neither
        // advance again nor emit a second failover event.
        assertFalse(reporter.reportFailure(listOf("1.1.1.1", "8.8.8.8")))
        assertEquals(1, reported.size)
    }

    @Test
    fun `health loop reports against the running engine's frozen order`() {
        val reported = mutableListOf<Pair<String, String>>()
        val reporter = reporter(reported)

        // The engine now running was verified with the default order.
        reporter.activate(listOf("1.1.1.1", "8.8.8.8"))
        // Three consecutive health strikes: only the first may advance, or the recovery
        // reconnect would skip past a resolver that was never tried.
        assertTrue(reporter.reportFailure())
        assertFalse(reporter.reportFailure())
        assertFalse(reporter.reportFailure())

        assertEquals(1, reported.size)
        assertEquals(listOf("8.8.8.8", "1.1.1.1"), reporter.currentServers())
    }

    @Test
    fun `a stale active order cannot advance past an untried resolver`() {
        val reported = mutableListOf<Pair<String, String>>()
        val reporter = reporter(reported)

        reporter.activate(listOf("1.1.1.1", "8.8.8.8"))
        // Startup already rotated after this engine started (e.g. a later epoch's DNS failure).
        assertTrue(reporter.reportFailure(listOf("1.1.1.1", "8.8.8.8")))
        reported.clear()

        // The health loop's strike still names the retired order: it must be absorbed, leaving
        // the freshly-promoted resolver in place to actually be tried.
        assertFalse(reporter.reportFailure())
        assertTrue(reported.isEmpty())
        assertEquals(listOf("8.8.8.8", "1.1.1.1"), reporter.currentServers())
    }

    @Test
    fun `activate re-freezes the order for the next engine`() {
        val reported = mutableListOf<Pair<String, String>>()
        val reporter = reporter(reported)

        reporter.activate(listOf("1.1.1.1", "8.8.8.8"))
        assertTrue(reporter.reportFailure())
        // The recovery reconnect verified a new engine on the rotated order.
        reporter.activate(reporter.currentServers())
        assertTrue(reporter.reportFailure())

        assertEquals(
            listOf("1.1.1.1" to "8.8.8.8", "8.8.8.8" to "1.1.1.1"),
            reported,
        )
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), reporter.currentServers())
    }

    @Test
    fun `resolver count is exposed for the same-relay retry budget`() {
        assertEquals(
            DnsResolverRotation.DEFAULT_RESOLVERS.size,
            reporter(mutableListOf()).resolverCount,
        )
    }

    private fun reporter(sink: MutableList<Pair<String, String>>) = DnsFailoverReporter(
        rotation = DnsResolverRotation(),
        onFailover = { failed, next -> sink.add(failed to next) },
    )
}
