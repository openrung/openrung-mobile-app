package com.openrung.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

@OptIn(ExperimentalCoroutinesApi::class)
class WssTicketClientTest {
    @Test
    fun `fixed endpoint preserves a base path and allows cleartext only on loopback`() {
        assertEquals(
            "https://broker.example/base/api/v1/wss/tickets",
            WssTicketClient.ticketEndpoint(" https://broker.example/base/?old=1#discarded ").toString(),
        )
        assertEquals(
            "http://127.0.0.1:8080/api/v1/wss/tickets",
            WssTicketClient.ticketEndpoint("http://127.0.0.1:8080/").toString(),
        )
        assertEquals(
            "http://[::1]:8080/dev/api/v1/wss/tickets",
            WssTicketClient.ticketEndpoint("http://[::1]:8080/dev").toString(),
        )

        assertThrows(IllegalArgumentException::class.java) {
            WssTicketClient.ticketEndpoint("http://broker.example/")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WssTicketClient.ticketEndpoint("https://user@broker.example/")
        }
        assertThrows(IllegalArgumentException::class.java) {
            WssTicketClient.ticketEndpoint("ftp://broker.example/")
        }
    }

    @Test
    fun `POST uses no-store headers and emits identity headers only as a complete pair`() = runBlocking {
        val now = Instant.parse("2026-07-22T00:00:00Z")
        val response = ticketJson(
            ticket = "opaque-ticket",
            expiresAt = now.plusSeconds(120),
            url = FRONT_URL,
        )
        val connectionsUsed = listOf(
            RecordingHttpURLConnection(URL("http://127.0.0.1/ignored"), 201, response),
            RecordingHttpURLConnection(URL("http://127.0.0.1/ignored"), 201, response),
        )
        val connections = ArrayDeque(connectionsUsed)
        val openedUrls = mutableListOf<URL>()
        val openConnection: (URL) -> HttpURLConnection = { url ->
            openedUrls += url
            connections.removeFirst()
        }
        val result = WssTicketClient.requestOnce(
            brokerUrl = "http://127.0.0.1:8080/custom/",
            relayId = "relay-a",
            frontId = "front-a",
            clientId = "client-a",
            sessionId = "session-a",
            now = { now },
            openConnection = openConnection,
        )

        assertEquals("opaque-ticket", result.ticket)
        assertEquals(now.plusSeconds(120), result.expiresAt)
        assertEquals(FRONT_URL, result.url)
        assertEquals("/custom/api/v1/wss/tickets", openedUrls[0].path)
        connectionsUsed[0].capture().also { request ->
            assertEquals("POST", request.method)
            assertEquals("{\"relay_id\":\"relay-a\",\"front_id\":\"front-a\"}", request.body)
            assertEquals("application/json", request.accept)
            assertEquals("application/json", request.contentType)
            assertEquals("no-store", request.cacheControl)
            assertEquals("no-cache", request.pragma)
            assertEquals("client-a", request.clientId)
            assertEquals("session-a", request.sessionId)
        }

        WssTicketClient.requestOnce(
            brokerUrl = "http://127.0.0.1:8080/custom/",
            relayId = "relay-a",
            frontId = "front-a",
            clientId = "client-without-session",
            sessionId = null,
            now = { now },
            openConnection = openConnection,
        )
        connectionsUsed[1].capture().also { request ->
            assertNull(request.clientId)
            assertNull(request.sessionId)
        }
        Unit
    }

    @Test
    fun `redirect is rejected and status diagnostic never includes its response body`() = runBlocking {
        val connection = RecordingHttpURLConnection(
            url = URL("http://127.0.0.1/ignored"),
            statusCode = 307,
            body = "secret-origin-response-body",
            responseHeaders = mapOf(
                "Location" to "/credential-sink",
                "Retry-After" to "7",
            ),
        )
        val error = assertSuspendThrows<WssTicketStatusException> {
            WssTicketClient.requestOnce(
                brokerUrl = "http://127.0.0.1/base",
                relayId = "relay-a",
                frontId = "front-a",
                now = { Instant.EPOCH },
                openConnection = { connection },
            )
        }

        assertEquals(307, error.status)
        assertEquals(7_000L, error.retryAfterMillis)
        assertFalse(error.toString().contains("secret-origin-response-body"))
        assertFalse(connection.instanceFollowRedirects)
        assertEquals(0, connection.inputStreamAccesses.get())
    }

    @Test
    fun `successful response is bounded and validates opaque ticket URL and expiry`() = runBlocking {
        val now = Instant.parse("2026-07-22T00:00:00Z")

        val oversizedResponse = assertSuspendThrows<IOException> {
            requestFromBody("x".repeat(64 * 1_024 + 1), now)
        }
        assertTrue(oversizedResponse.message.orEmpty().contains("exceeds 65536"))

        val oversizedTicket = assertSuspendThrows<IOException> {
            requestFromBody(ticketJson("t".repeat(4_097), now.plusSeconds(60), FRONT_URL), now)
        }
        assertTrue(oversizedTicket.message.orEmpty().contains("oversized ticket"))

        val expired = assertSuspendThrows<IOException> {
            requestFromBody(ticketJson("ticket", now, FRONT_URL), now)
        }
        assertTrue(expired.message.orEmpty().contains("expired"))

        val missingUrl = assertSuspendThrows<IOException> {
            requestFromBody(ticketJson("ticket", now.plusSeconds(60), ""), now)
        }
        assertTrue(missingUrl.message.orEmpty().contains("no URL"))

        val headerInjection = assertSuspendThrows<IOException> {
            requestFromBody(ticketJson("ticket\r\ninjected", now.plusSeconds(60), FRONT_URL), now)
        }
        assertTrue(headerInjection.message.orEmpty().contains("oversized ticket"))

        val maximumTicket = requestFromBody(
            ticketJson("t".repeat(4_096), now.plusSeconds(60), FRONT_URL),
            now,
        )
        assertEquals(4_096, maximumTicket.ticket.length)
    }

    @Test
    fun `broker fronts fail over sequentially and preserve the first all-fail diagnostic`() = runTest {
        val firstFailure = IOException("primary diagnostic")
        val calls = mutableListOf<Pair<String, Long>>()
        val success = ticket("from-secondary")
        val result = WssTicketClient.requestWithFailover(
            brokerUrls = listOf(" https://primary.example/ ", "https://secondary.example/", "https://primary.example/"),
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

        val secondaryFailure = IOException("secondary diagnostic")
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
                    if (broker.contains("primary")) throw firstFailure else throw secondaryFailure
                },
            )
        }
        // withTimeout may recover a same-type diagnostic copy for coroutine stack traces.
        assertEquals(firstFailure.message, surfaced.message)
    }

    @Test
    fun `429 and 503 permit one retry round with default and maximum delay bounds`() = runTest {
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
                    1 -> throw WssTicketStatusException(429, null) // invalid/missing hint -> default
                    2 -> throw WssTicketStatusException(503, 120_000) // oversized hint -> maximum
                    else -> success
                }
            },
        )

        assertSame(success, result)
        assertEquals(
            listOf("https://primary.example/", "https://secondary.example/", "https://primary.example/"),
            calls,
        )
        assertEquals(listOf(30_000L), waits)
        assertEquals(30_000L, testScheduler.currentTime)
    }

    @Test
    fun `retry never exceeds one extra round and cannot consume the total deadline`() = runTest {
        val first = WssTicketStatusException(429, 0)
        val second = WssTicketStatusException(429, 1)
        var calls = 0
        val waits = mutableListOf<Long>()
        val surfaced = assertSuspendThrows<WssTicketStatusException> {
            WssTicketClient.requestWithFailover(
                brokerUrls = listOf("https://primary.example/"),
                relayId = "relay-a",
                frontId = "front-a",
                clientId = null,
                sessionId = null,
                policy = WssTicketPolicy(
                    totalDeadlineMillis = 20_000,
                    defaultRetryAfterMillis = 1_000,
                    maxRetryAfterMillis = 2_000,
                ),
                elapsedRealtimeMillis = { testScheduler.currentTime },
                wait = {
                    waits += it
                    delay(it)
                },
                attempt = { _, _, _, _, _, _ ->
                    calls++
                    throw if (calls == 1) first else second
                },
            )
        }
        assertSame(first, surfaced)
        assertEquals(2, calls)
        assertEquals(listOf(1_000L), waits)

        calls = 0
        waits.clear()
        val deadlineFailure = WssTicketStatusException(503, null)
        val bounded = assertSuspendThrows<WssTicketStatusException> {
            WssTicketClient.requestWithFailover(
                brokerUrls = listOf("https://primary.example/"),
                relayId = "relay-a",
                frontId = "front-a",
                clientId = null,
                sessionId = null,
                policy = WssTicketPolicy(
                    totalDeadlineMillis = 8_000,
                    defaultRetryAfterMillis = 10_000,
                ),
                elapsedRealtimeMillis = { testScheduler.currentTime },
                wait = {
                    waits += it
                    delay(it)
                },
                attempt = { _, _, _, _, _, _ ->
                    calls++
                    throw deadlineFailure
                },
            )
        }
        assertSame(deadlineFailure, bounded)
        assertEquals(1, calls)
        assertTrue(waits.isEmpty())
    }

    @Test
    fun `Retry-After parses dates rejects invalid values and saturates huge deltas`() {
        val now = Instant.parse("2026-07-22T00:00:00Z")
        val date = DateTimeFormatter.RFC_1123_DATE_TIME.format(now.plusSeconds(17).atZone(ZoneOffset.UTC))

        assertEquals(12_000L, WssTicketClient.parseRetryAfterMillis(" 12 ", now))
        assertEquals(0L, WssTicketClient.parseRetryAfterMillis("000", now))
        assertEquals(17_000L, WssTicketClient.parseRetryAfterMillis(date, now))
        assertNull(WssTicketClient.parseRetryAfterMillis("-1", now))
        assertNull(WssTicketClient.parseRetryAfterMillis("not-a-date", now))
        assertEquals(
            Long.MAX_VALUE,
            WssTicketClient.parseRetryAfterMillis("9223372036854775807", now),
        )
        assertNull(
            WssTicketClient.parseRetryAfterMillis(
                DateTimeFormatter.RFC_1123_DATE_TIME.format(now.minusSeconds(1).atZone(ZoneOffset.UTC)),
                now,
            ),
        )
    }

    @Test
    fun `cancelling a blocked request disconnects its HttpURLConnection`() = runBlocking {
        val connection = BlockingHttpURLConnection(URL("http://127.0.0.1/"))
        val request = launch(Dispatchers.Default) {
            runCatching {
                WssTicketClient.requestOnce(
                    brokerUrl = "http://127.0.0.1/",
                    relayId = "relay-a",
                    frontId = "front-a",
                    openConnection = { connection },
                )
            }
        }

        assertTrue("request did not reach responseCode", connection.responseStarted.await(2, TimeUnit.SECONDS))
        request.cancelAndJoin()
        assertTrue("disconnect did not release blocked I/O", connection.disconnected.await(2, TimeUnit.SECONDS))
        assertTrue(connection.disconnectCalls.get() >= 1)
    }

    private suspend fun requestFromBody(body: String, now: Instant): WssSessionTicket =
        WssTicketClient.requestOnce(
            brokerUrl = "http://127.0.0.1/",
            relayId = "relay-a",
            frontId = "front-a",
            now = { now },
            openConnection = { url -> RecordingHttpURLConnection(url, 201, body) },
        )

    private fun ticket(value: String): WssSessionTicket = WssSessionTicket(
        ticket = value,
        expiresAt = Instant.parse("2030-01-01T00:00:00Z"),
        url = FRONT_URL,
    )

    private fun ticketJson(ticket: String, expiresAt: Instant, url: String): String =
        "{\"ticket\":\"${ticket.jsonEscape()}\",\"expires_at\":\"$expiresAt\",\"url\":\"${url.jsonEscape()}\"}"

    private fun String.jsonEscape(): String = buildString(length) {
        this@jsonEscape.forEach { character ->
            when (character) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\r' -> append("\\r")
                '\n' -> append("\\n")
                else -> append(character)
            }
        }
    }

    private data class CapturedRequest(
        val method: String,
        val body: String,
        val accept: String?,
        val contentType: String?,
        val cacheControl: String?,
        val pragma: String?,
        val clientId: String?,
        val sessionId: String?,
    )

    private class RecordingHttpURLConnection(
        url: URL,
        private val statusCode: Int,
        body: String,
        private val responseHeaders: Map<String, String> = emptyMap(),
    ) : HttpURLConnection(url) {
        private val response = ByteArrayInputStream(body.toByteArray(Charsets.UTF_8))
        private val request = ByteArrayOutputStream()
        val inputStreamAccesses = AtomicInteger()

        override fun connect() = Unit
        override fun disconnect() = Unit
        override fun usingProxy(): Boolean = false
        override fun getOutputStream(): OutputStream = request
        override fun getInputStream(): InputStream {
            inputStreamAccesses.incrementAndGet()
            return response
        }
        override fun getResponseCode(): Int = statusCode
        override fun getHeaderField(name: String?): String? = responseHeaders.entries
            .firstOrNull { it.key.equals(name, ignoreCase = true) }
            ?.value

        fun capture(): CapturedRequest = CapturedRequest(
            method = requestMethod,
            body = request.toString(Charsets.UTF_8.name()),
            accept = getRequestProperty("Accept"),
            contentType = getRequestProperty("Content-Type"),
            cacheControl = getRequestProperty("Cache-Control"),
            pragma = getRequestProperty("Pragma"),
            clientId = getRequestProperty("X-OpenRung-Client-ID"),
            sessionId = getRequestProperty("X-OpenRung-Session-ID"),
        )
    }

    private class BlockingHttpURLConnection(url: URL) : HttpURLConnection(url) {
        val responseStarted = CountDownLatch(1)
        val disconnected = CountDownLatch(1)
        val disconnectCalls = AtomicInteger()
        private val request = ByteArrayOutputStream()

        override fun connect() = Unit

        override fun disconnect() {
            disconnectCalls.incrementAndGet()
            disconnected.countDown()
        }

        override fun usingProxy(): Boolean = false
        override fun getOutputStream(): OutputStream = request

        override fun getResponseCode(): Int {
            responseStarted.countDown()
            if (!disconnected.await(5, TimeUnit.SECONDS)) {
                throw IOException("test connection was not disconnected")
            }
            throw IOException("connection disconnected")
        }
    }

    private suspend inline fun <reified T : Throwable> assertSuspendThrows(
        crossinline block: suspend () -> Unit,
    ): T {
        try {
            block()
        } catch (error: Throwable) {
            if (error is T) return error
            throw AssertionError("expected ${T::class.java.name}, got ${error::class.java.name}", error)
        }
        fail("expected ${T::class.java.name}")
        throw AssertionError("unreachable")
    }

    companion object {
        private const val FRONT_URL = "wss://front.example/api/v1/wss-bridge"
    }
}
