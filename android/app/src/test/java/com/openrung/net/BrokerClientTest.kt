package com.openrung.net

import com.openrung.config.AppConfig
import com.openrung.model.RelayListResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

private const val PRIMARY = "https://primary.example/"
private const val FALLBACK = "https://fallback.example/"

/**
 * Virtual-time tests for the staggered-race discovery in [BrokerClient.firstReachable], driven
 * through the internal fetch-injectable overload so no real sockets (or real 2.5 s staggers) are
 * involved. Mirrors the reference TypeScript suite (`__tests__/core/brokerClient.test.ts`) — the
 * race semantics must stay identical across the desktop Go, RN TypeScript, Kotlin and Swift
 * clients.
 */
class BrokerClientTest {

    private val relayList =
        RelayListResponse(count = 0, serverTime = "2026-07-10T00:00:00Z", relays = emptyList())

    @Test
    fun `healthy primary wins without the fallback ever starting`() = runTest {
        val started = mutableListOf<String>()
        val fetch = BrokerClient.firstReachable(listOf(PRIMARY, FALLBACK)) { url ->
            started += url
            delay(40) // healthy: answers well inside the first stagger window
            relayList
        }
        assertEquals(PRIMARY, fetch.brokerUrl)
        assertEquals(40L, currentTime)
        // Long after the race settled, no leftover stagger timer may fire: the fallback front
        // never sees a request while the primary is healthy.
        advanceTimeBy(3 * AppConfig.DISCOVERY_STAGGER_MS)
        assertEquals(listOf(PRIMARY), started)
    }

    @Test
    fun `fallback beats a hanging primary one stagger in and the loser is cancelled`() = runTest {
        var primaryCancelled = false
        val fetch = BrokerClient.firstReachable(listOf(PRIMARY, FALLBACK)) { url ->
            if (url == PRIMARY) {
                try {
                    awaitCancellation() // blackholed: never answers, never fails
                } catch (cancellation: CancellationException) {
                    primaryCancelled = true
                    throw cancellation
                }
            }
            relayList
        }
        // The later candidate that succeeds first wins even though the earlier-priority attempt
        // is still pending — priority is only a head start (spec point 2).
        assertEquals(FALLBACK, fetch.brokerUrl)
        assertEquals(AppConfig.DISCOVERY_STAGGER_MS, currentTime)
        // ... and the losing attempt was aborted for real, not left running to its timeout.
        assertTrue(primaryCancelled)
    }

    @Test
    fun `one candidate joins the race per stagger and a late winner cancels every loser`() = runTest {
        val urls = listOf("https://a.example/", "https://b.example/", "https://c.example/")
        val startTimes = linkedMapOf<String, Long>()
        val cancelled = mutableSetOf<String>()
        val fetch = BrokerClient.firstReachable(urls) { url ->
            startTimes[url] = currentTime
            if (url != urls.last()) {
                try {
                    awaitCancellation()
                } catch (cancellation: CancellationException) {
                    cancelled += url
                    throw cancellation
                }
            }
            relayList
        }
        assertEquals(urls.last(), fetch.brokerUrl)
        assertEquals(
            mapOf(
                urls[0] to 0L,
                urls[1] to AppConfig.DISCOVERY_STAGGER_MS,
                urls[2] to 2 * AppConfig.DISCOVERY_STAGGER_MS,
            ),
            startTimes,
        )
        // The winner is never cancelled; every pending loser is.
        assertEquals(setOf(urls[0], urls[1]), cancelled)
    }

    @Test
    fun `all candidates failing surfaces the primary error on the unaccelerated cadence`() = runTest {
        val urls = listOf("https://a.example/", "https://b.example/", "https://c.example/")
        val startTimes = mutableListOf<Long>()
        val primaryError = IOException("primary down")
        val thrown = runCatching {
            BrokerClient.firstReachable(urls) { url ->
                startTimes += currentTime
                throw if (url == urls.first()) primaryError else IOException("$url down")
            }
        }.exceptionOrNull()
        // The FIRST candidate's failure is the surfaced diagnostic, not the last-observed one
        // (spec point 4). Coroutine stack-trace recovery may rewrap the instance, but then the
        // original is attached as the cause and the type/message are preserved.
        assertTrue(thrown === primaryError || thrown?.cause === primaryError)
        assertEquals("primary down", thrown?.message)
        // Instant failures never pull later starts forward: the cadence stays 0 / 1x / 2x
        // stagger (spec point 1).
        assertEquals(
            listOf(0L, AppConfig.DISCOVERY_STAGGER_MS, 2 * AppConfig.DISCOVERY_STAGGER_MS),
            startTimes,
        )
    }

    @Test
    fun `a single candidate behaves exactly like the old sequential attempt`() = runTest {
        var attempts = 0
        val error = IOException("only broker down")
        val thrown = runCatching {
            BrokerClient.firstReachable(listOf(PRIMARY)) {
                attempts++
                throw error
            }
        }.exceptionOrNull()
        assertEquals(1, attempts)
        assertTrue(thrown === error || thrown?.cause === error)
        assertEquals("only broker down", thrown?.message)
        assertEquals(0L, currentTime) // no stagger timer was ever scheduled (spec point 5)
    }

    @Test
    fun `an empty candidate list is rejected up front`() = runTest {
        val thrown = runCatching {
            BrokerClient.firstReachable(emptyList()) { relayList }
        }.exceptionOrNull()
        assertTrue(thrown is IllegalArgumentException)
        assertEquals("no broker endpoints configured", thrown?.message)
    }
}
