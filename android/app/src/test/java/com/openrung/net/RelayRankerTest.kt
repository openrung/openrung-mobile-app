package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

class RelayRankerTest {
    @Test
    fun `sorts probed relays by latency bucket, fastest first`() = runTest {
        val relays = listOf(relay("a"), relay("b"), relay("c"))
        val latencies = mapOf("a" to 200L, "b" to 40L, "c" to 120L)

        val ranked = RelayRanker.rankByTcpLatency(relays) { r, _ -> latencies.getValue(r.id) }

        assertEquals(listOf("b", "c", "a"), ranked.map { it.relay.id })
        assertEquals(listOf(40L, 120L, 200L), ranked.map { it.probeMs })
    }

    @Test
    fun `broker order decides within a latency bucket`() = runTest {
        // 31 and 45 share the 30ms bucket; broker order (a before b) must survive even though
        // b measured marginally faster. c's 95 lands two buckets up and sorts last.
        val relays = listOf(relay("a"), relay("b"), relay("c"))
        val latencies = mapOf("a" to 45L, "b" to 31L, "c" to 95L)

        val ranked = RelayRanker.rankByTcpLatency(relays) { r, _ -> latencies.getValue(r.id) }

        assertEquals(listOf("a", "b", "c"), ranked.map { it.relay.id })
    }

    @Test
    fun `failed probes sink below reachable relays but are never dropped`() = runTest {
        val relays = listOf(relay("dead"), relay("slow"), relay("fast"))

        val ranked = RelayRanker.rankByTcpLatency(relays) { r, _ ->
            when (r.id) {
                "dead" -> throw IllegalStateException("connect timed out")
                "slow" -> 400L
                else -> 20L
            }
        }

        assertEquals(listOf("fast", "slow", "dead"), ranked.map { it.relay.id })
        assertNull(ranked.last().probeMs)
    }

    @Test
    fun `unprobed tail keeps broker order after the probed head`() = runTest {
        val relays = (1..5).map { relay("r$it") }
        // Probe only the first three; reverse their latency so the head visibly reorders.
        val latencies = mapOf("r1" to 300L, "r2" to 150L, "r3" to 10L)

        val ranked = RelayRanker.rankByTcpLatency(relays, maxProbes = 3) { r, _ ->
            latencies.getValue(r.id)
        }

        assertEquals(listOf("r3", "r2", "r1", "r4", "r5"), ranked.map { it.relay.id })
        assertNull(ranked[3].probeMs)
        assertNull(ranked[4].probeMs)
    }

    @Test
    fun `single candidate short-circuits without probing`() = runTest {
        val probes = AtomicInteger(0)

        val ranked = RelayRanker.rankByTcpLatency(listOf(relay("only"))) { _, _ ->
            probes.incrementAndGet()
            10L
        }

        assertEquals(listOf("only"), ranked.map { it.relay.id })
        assertNull(ranked.single().probeMs)
        assertEquals(0, probes.get())
    }

    @Test
    fun `probes run concurrently, not sequentially`() = runTest {
        val relays = (1..4).map { relay("r$it") }

        RelayRanker.rankByTcpLatency(relays) { _, _ ->
            delay(1_000)
            50L
        }

        // Four sequential probes would advance virtual time to 4000ms.
        assertEquals(1_000L, currentTime)
    }

    private fun relay(id: String): RelayDescriptor = RelayDescriptor(
        id = id,
        publicHost = "203.0.113.10",
        publicPort = 443,
        relayProtocol = "vless-reality-vision",
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "key",
        shortId = "abcd",
        serverName = "www.example.com",
        flow = "xtls-rprx-vision",
        exitMode = "direct",
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        registeredAt = "2026-01-01T00:00:00Z",
        lastHeartbeatAt = "2026-01-01T00:00:00Z",
        expiresAt = "2026-01-01T01:00:00Z",
    )
}
