package com.openrung.net

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.time.Instant

@OptIn(ExperimentalCoroutinesApi::class)
class WssTicketClientTest {
    @Test
    fun `ticket string representation redacts bearer and URL`() {
        val ticket = "opaque-ticket-that-must-never-reach-logs"
        val url = "wss://secret-front.example/credential-path"
        val value = WssSessionTicket(
            ticket = ticket,
            expiresAt = Instant.parse("2026-07-26T00:01:00Z"),
            url = url,
        ).toString()

        assertFalse(value.contains(ticket))
        assertFalse(value.contains(url))
        assertFalse(value.contains("secret-front.example"))
        assertTrue(value.contains("ticket=<redacted>"))
        assertTrue(value.contains("url=<redacted>"))
    }

    @Test
    fun `requestOnce forwards exact fields and converts Unix milliseconds`() = runBlocking {
        val expiryMillis = 1_785_024_060_123L
        val operation = RecordingNativeBrokerOperation().apply {
            wssTicketResult = NativeBrokerWssTicketResult(
                succeeded = true,
                ticket = "opaque-ticket",
                url = FRONT_URL,
                expiresAtMillis = expiryMillis,
            )
        }

        val result = WssTicketClient.requestOnce(
            brokerUrl = " https://broker.example/base ",
            relayId = "relay-a",
            frontId = "front-a",
            clientId = "client-a",
            sessionId = "session-a",
            operationFactory = RecordingNativeBrokerOperationFactory(operation),
        )

        assertEquals(
            WssTicketCall(
                brokerUrl = " https://broker.example/base ",
                relayId = "relay-a",
                frontId = "front-a",
                clientId = "client-a",
                sessionId = "session-a",
            ),
            operation.wssTicketCalls.single(),
        )
        assertEquals("opaque-ticket", result.ticket)
        assertEquals(FRONT_URL, result.url)
        assertEquals(Instant.ofEpochMilli(expiryMillis), result.expiresAt)
        assertEquals(1, operation.closeCalls.get())
    }

    @Test
    fun `requestOnce maps native status and zero Retry-After to typed absence`() = runBlocking {
        val operation = RecordingNativeBrokerOperation().apply {
            wssTicketResult = NativeBrokerWssTicketResult(
                succeeded = false,
                errorKind = "http_status",
                errorText = "temporarily unavailable",
                httpStatus = 503,
                retryAfterMillis = 0,
            )
        }
        val failure = assertSuspendThrows<WssTicketStatusException> {
            WssTicketClient.requestOnce(
                brokerUrl = "https://broker.example/",
                relayId = "relay-a",
                frontId = "front-a",
                operationFactory = RecordingNativeBrokerOperationFactory(operation),
            )
        }

        assertEquals(503, failure.status)
        assertNull(failure.retryAfterMillis)
        assertTrue(failure.cause is BrokerNativeFailure)
        assertFalse(failure.toString().contains("temporarily unavailable"))
    }

    @Test
    fun `broker fronts are ordered deduplicated and first success wins`() = runTest {
        val firstFailure = IOException("primary diagnostic")
        val calls = mutableListOf<Pair<String, Long>>()
        val success = ticket("from-secondary")
        val result = WssTicketClient.requestWithFailover(
            brokerUrls = listOf(
                " https://primary.example/ ",
                "https://secondary.example/",
                "https://primary.example/",
            ),
            relayId = "relay-a",
            frontId = "front-a",
            clientId = "client-a",
            sessionId = "session-a",
            policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
            elapsedRealtimeMillis = { testScheduler.currentTime },
            wait = { delay(it) },
            attempt = { broker, relay, front, client, session, timeout ->
                calls += broker to timeout
                assertEquals("relay-a", relay)
                assertEquals("front-a", front)
                assertEquals("client-a", client)
                assertEquals("session-a", session)
                if (broker.contains("primary")) throw firstFailure
                success
            },
        )

        assertSame(success, result)
        assertEquals(
            listOf("https://primary.example/" to 5_000L, "https://secondary.example/" to 5_000L),
            calls,
        )
    }

    @Test
    fun `all failures retain the first front diagnostic`() = runTest {
        val first = IOException("primary diagnostic")
        val second = IOException("secondary diagnostic")
        val surfaced = assertSuspendThrows<IOException> {
            WssTicketClient.requestWithFailover(
                brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
                relayId = "relay-a",
                frontId = "front-a",
                clientId = null,
                sessionId = null,
                policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
                elapsedRealtimeMillis = { testScheduler.currentTime },
                wait = { delay(it) },
                attempt = { broker, _, _, _, _, _ ->
                    if (broker.contains("primary")) throw first else throw second
                },
            )
        }

        assertEquals(first.message, surfaced.message)
    }

    @Test
    fun `429 and 503 permit one bounded retry round and zero uses default delay`() = runTest {
        val calls = mutableListOf<String>()
        val waits = mutableListOf<Long>()
        val success = ticket("retry-success")
        val result = WssTicketClient.requestWithFailover(
            brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
            relayId = "relay-a",
            frontId = "front-a",
            clientId = null,
            sessionId = null,
            policy = WssTicketPolicy(
                totalDeadlineMillis = 60_000,
                defaultRetryAfterMillis = 10_000,
                maxRetryAfterMillis = 30_000,
            ),
            elapsedRealtimeMillis = { testScheduler.currentTime },
            wait = {
                waits += it
                delay(it)
            },
            attempt = { broker, _, _, _, _, _ ->
                calls += broker
                when (calls.size) {
                    1 -> throw WssTicketStatusException(429, null)
                    2 -> throw WssTicketStatusException(503, 120_000)
                    else -> success
                }
            },
        )

        assertSame(success, result)
        assertEquals(
            listOf(
                "https://primary.example/",
                "https://secondary.example/",
                "https://primary.example/",
            ),
            calls,
        )
        assertEquals(listOf(30_000L), waits)

        calls.clear()
        waits.clear()
        val zeroHintSuccess = WssTicketClient.requestWithFailover(
            brokerUrls = listOf("https://primary.example/"),
            relayId = "relay-a",
            frontId = "front-a",
            clientId = null,
            sessionId = null,
            policy = WssTicketPolicy(totalDeadlineMillis = 30_000),
            elapsedRealtimeMillis = { testScheduler.currentTime },
            wait = {
                waits += it
                delay(it)
            },
            attempt = { _, _, _, _, _, _ ->
                calls += "call"
                if (calls.size == 1) throw WssTicketStatusException(429, 0)
                success
            },
        )
        assertSame(success, zeroHintSuccess)
        assertEquals(listOf(10_000L), waits)
        assertEquals(2, calls.size)
    }

    @Test
    fun `non 429 or 503 statuses do not schedule a second round`() = runTest {
        val calls = mutableListOf<String>()
        val waits = mutableListOf<Long>()
        val first = WssTicketStatusException(500, 1)
        val surfaced = assertSuspendThrows<WssTicketStatusException> {
            WssTicketClient.requestWithFailover(
                brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
                relayId = "relay-a",
                frontId = "front-a",
                clientId = null,
                sessionId = null,
                policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
                elapsedRealtimeMillis = { testScheduler.currentTime },
                wait = {
                    waits += it
                    delay(it)
                },
                attempt = { broker, _, _, _, _, _ ->
                    calls += broker
                    if (calls.size == 1) throw first
                    throw WssTicketStatusException(404, 1)
                },
            )
        }

        assertEquals(first.status, surfaced.status)
        assertEquals(2, calls.size)
        assertTrue(waits.isEmpty())
    }

    @Test
    fun `local native failures abort ladder without consuming another ticket`() = runTest {
        BrokerNativeFailureKind.entries
            .filter {
                it == BrokerNativeFailureKind.VALIDATION ||
                    it == BrokerNativeFailureKind.UNAVAILABLE ||
                    it == BrokerNativeFailureKind.DECODE
            }
            .forEach { kind ->
                var calls = 0
                val failure = BrokerNativeFailure(kind = kind, message = "local failure")
                val surfaced = assertSuspendThrows<BrokerNativeFailure> {
                    WssTicketClient.requestWithFailover(
                        brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
                        relayId = "relay-a",
                        frontId = "front-a",
                        clientId = null,
                        sessionId = null,
                        policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
                        elapsedRealtimeMillis = { testScheduler.currentTime },
                        wait = { delay(it) },
                        attempt = { _, _, _, _, _, _ ->
                            calls++
                            throw failure
                        },
                    )
                }
                assertSame(failure, surfaced)
                assertEquals(1, calls)
            }
    }

    // Real time on purpose: requestOnce hops through Dispatchers.IO, which runTest's virtual
    // clock treats as idle waiting, expiring the per-attempt withTimeout before the fake returns.
    @Test
    fun `spurious native cancelled attempt is a typed failure and fails over to the next front`() = runBlocking {
        val cancelledOperation = RecordingNativeBrokerOperation().apply {
            wssTicketResult = NativeBrokerWssTicketResult(
                succeeded = false,
                errorKind = "cancelled",
                errorText = "request cancelled",
            )
        }
        val successOperation = RecordingNativeBrokerOperation().apply {
            wssTicketResult = NativeBrokerWssTicketResult(
                succeeded = true,
                ticket = "opaque-ticket",
                url = FRONT_URL,
                expiresAtMillis = 1_785_024_060_123,
            )
        }
        val factory = RecordingNativeBrokerOperationFactory(cancelledOperation, successOperation)

        // A native "cancelled" kind with this caller still live is one failed attempt, not epoch
        // cancellation: failover must continue to the next front instead of aborting the ladder.
        val result = WssTicketClient.requestWithFailover(
            brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
            relayId = "relay-a",
            frontId = "front-a",
            clientId = null,
            sessionId = null,
            policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
            elapsedRealtimeMillis = { 0L },
            wait = {},
            attempt = { brokerUrl, relayId, frontId, clientId, sessionId, timeout ->
                WssTicketClient.requestOnce(
                    brokerUrl = brokerUrl,
                    relayId = relayId,
                    frontId = frontId,
                    clientId = clientId,
                    sessionId = sessionId,
                    timeoutMillis = timeout,
                    operationFactory = factory,
                )
            },
        )

        assertEquals("opaque-ticket", result.ticket)
        assertEquals(1, cancelledOperation.wssTicketCalls.size)
        assertEquals(1, successOperation.wssTicketCalls.size)
    }

    @Test
    fun `caller cancellation propagates and never attempts another front`() = runTest {
        val calls = mutableListOf<String>()
        var observed: Throwable? = null
        val request = launch {
            try {
                WssTicketClient.requestWithFailover(
                    brokerUrls = listOf("https://primary.example/", "https://secondary.example/"),
                    relayId = "relay-a",
                    frontId = "front-a",
                    clientId = null,
                    sessionId = null,
                    policy = WssTicketPolicy(totalDeadlineMillis = 20_000),
                    elapsedRealtimeMillis = { testScheduler.currentTime },
                    wait = { delay(it) },
                    attempt = { broker, _, _, _, _, _ ->
                        calls += broker
                        awaitCancellation()
                    },
                )
            } catch (error: Throwable) {
                observed = error
                throw error
            }
        }
        runCurrent()
        request.cancelAndJoin()

        assertTrue(observed is CancellationException)
        assertEquals(listOf("https://primary.example/"), calls)
    }

    @Test
    fun `one total deadline bounds per-attempt budgets`() = runTest {
        val timeouts = mutableListOf<Long>()
        val first = IOException("primary failed")
        val surfaced = assertSuspendThrows<IOException> {
            WssTicketClient.requestWithFailover(
                brokerUrls = listOf("https://a.example/", "https://b.example/"),
                relayId = "relay-a",
                frontId = "front-a",
                clientId = null,
                sessionId = null,
                policy = WssTicketPolicy(totalDeadlineMillis = 7_000, perAttemptMillis = 5_000),
                elapsedRealtimeMillis = { testScheduler.currentTime },
                wait = { delay(it) },
                attempt = { _, _, _, _, _, timeout ->
                    timeouts += timeout
                    if (timeouts.size == 1) {
                        delay(4_000)
                        throw first
                    }
                    throw IOException("secondary failed")
                },
            )
        }

        assertEquals(first.message, surfaced.message)
        assertEquals(listOf(5_000L, 3_000L), timeouts)
    }

    private fun ticket(value: String): WssSessionTicket = WssSessionTicket(
        ticket = value,
        expiresAt = Instant.parse("2030-01-01T00:00:00Z"),
        url = FRONT_URL,
    )

    companion object {
        private const val FRONT_URL = "wss://front.example/api/v1/wss-bridge"
    }
}
