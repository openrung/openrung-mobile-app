package com.openrung.net

import com.openrung.config.AppConfig
import com.openrung.model.RelayListResponse
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException

private const val PRIMARY = "https://primary.example/"
private const val FALLBACK = "https://fallback.example/"

/** Wraps urls as a pure-race candidate list — what [BrokerClient.candidates] builds without an override. */
private fun noOverride(vararg urls: String) = BrokerClient.Candidates(urls.toList())

/** Wraps urls as a candidate list whose FIRST entry is a genuine user override. */
private fun withOverride(vararg urls: String) =
    BrokerClient.Candidates(urls.toList(), overrideFirst = true)

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
        val fetch = BrokerClient.firstReachable(noOverride(PRIMARY, FALLBACK)) { url ->
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
        val fetch = BrokerClient.firstReachable(noOverride(PRIMARY, FALLBACK)) { url ->
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
        val fetch = BrokerClient.firstReachable(BrokerClient.Candidates(urls)) { url ->
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
            BrokerClient.firstReachable(BrokerClient.Candidates(urls)) { url ->
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
            BrokerClient.firstReachable(noOverride(PRIMARY)) {
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
            BrokerClient.firstReachable(BrokerClient.Candidates(emptyList())) { relayList }
        }.exceptionOrNull()
        assertTrue(thrown is IllegalArgumentException)
        assertEquals("no broker endpoints configured", thrown?.message)
    }

    // User-override strict phase (spec point 6).

    @Test
    fun `an override slower than the stagger still wins and the default is never contacted`() = runTest {
        // The override answers only after 3 stagger intervals: under pure race semantics the
        // default front would long since have won; under override-first it must never even start.
        val started = mutableListOf<String>()
        val fetch = BrokerClient.firstReachable(withOverride(PRIMARY, FALLBACK)) { url ->
            started += url
            delay(3 * AppConfig.DISCOVERY_STAGGER_MS) // slower than the stagger, inside its timeout
            relayList
        }
        assertEquals(PRIMARY, fetch.brokerUrl)
        assertEquals(3 * AppConfig.DISCOVERY_STAGGER_MS, currentTime)
        // Long after the override won, no default has been contacted — there was never a race.
        advanceTimeBy(3 * AppConfig.DISCOVERY_STAGGER_MS)
        assertEquals(listOf(PRIMARY), started)
    }

    @Test
    fun `an override failure starts the remaining defaults on the race cadence`() = runTest {
        val urls = listOf("https://override.example/", "https://a.example/", "https://b.example/")
        val startTimes = linkedMapOf<String, Long>()
        val fetch = BrokerClient.firstReachable(BrokerClient.Candidates(urls, overrideFirst = true)) { url ->
            startTimes[url] = currentTime
            when (url) {
                urls[0] -> {
                    delay(1_000)
                    throw IOException("override down")
                }
                urls[1] -> awaitCancellation() // hangs; loses the remainder race
                else -> relayList
            }
        }
        assertEquals(urls[2], fetch.brokerUrl)
        assertEquals(
            mapOf(
                urls[0] to 0L,
                // The first default starts only when the override fails — not one stagger in —
                // and the next one joins a full stagger later, on the usual cadence.
                urls[1] to 1_000L,
                urls[2] to 1_000L + AppConfig.DISCOVERY_STAGGER_MS,
            ),
            startTimes,
        )
    }

    @Test
    fun `the override error is surfaced when the remainder race also fails`() = runTest {
        // The override is candidates[0]: its error stays the surfaced diagnostic (spec point 4) —
        // the user configured that broker, so its failure is what they need to see.
        val overrideError = IOException("override down")
        val thrown = runCatching {
            BrokerClient.firstReachable(withOverride(PRIMARY, FALLBACK)) { url ->
                throw if (url == PRIMARY) overrideError else IOException("fallback down")
            }
        }.exceptionOrNull()
        assertTrue(thrown === overrideError || thrown?.cause === overrideError)
        assertEquals("override down", thrown?.message)
    }

    @Test
    fun `a single overridden candidate behaves exactly like the old sequential attempt`() = runTest {
        var attempts = 0
        val error = IOException("only broker down")
        val thrown = runCatching {
            BrokerClient.firstReachable(withOverride(PRIMARY)) {
                attempts++
                throw error
            }
        }.exceptionOrNull()
        assertEquals(1, attempts)
        assertTrue(thrown === error || thrown?.cause === error)
        assertEquals(0L, currentTime) // no remainder race, no stagger timer
    }

    @Test
    fun `cancelling the caller mid-remainder-race propagates the cancellation`() = runTest {
        // The override fails fast, the remaining default hangs, then the caller cancels. The
        // surfaced error must be the cancellation — what the caller classifies on — not the
        // override's stale failure.
        var thrown: Throwable? = null
        val job = launch {
            try {
                BrokerClient.firstReachable(withOverride(PRIMARY, FALLBACK)) { url ->
                    if (url == PRIMARY) throw IOException("override down")
                    awaitCancellation()
                }
            } catch (error: Throwable) {
                thrown = error
                throw error
            }
        }
        advanceTimeBy(1) // let the override fail and the default start hanging
        job.cancelAndJoin()
        assertTrue(thrown is CancellationException)
    }
}
