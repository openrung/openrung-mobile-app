package com.openrung.net

import com.google.crypto.tink.subtle.Ed25519Sign
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.InetAddress
import java.net.ServerSocket
import java.time.Clock
import java.time.Instant
import java.time.ZoneOffset
import java.util.Base64
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

// Shared signing test vector (SPEC v1 §2.3) — TEST-ONLY key, duplicated per file because the
// constants are file-private (see RelayListVerifierTest for the verifier-level suite).
private const val TEST_SEED_B64 = "QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI="
private const val TEST_PUBKEY_HEX = "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12"
private const val TEST_KEY_ID = "3097e2dee2cb4a34"
private const val VECTOR_BODY =
    """{"count":1,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-10T00:30:00Z","key_id":"3097e2dee2cb4a34","channel":"api","limit":1,"relays":[]}"""
private const val VECTOR_HEADER =
    "ed25519;$TEST_KEY_ID;K5UmJWzoEZ1YHOqZFf5E+ocNOITSe3WPvOo0GuyCRoiAxUk4eo/jcfqiuaPhrNeYrK3i8QcYI3LIv+zbVYq9Bw=="

/**
 * One-shot raw-socket HTTP/1.1 fixture: unlike com.sun.net.httpserver it gives full control over
 * the header NAME CASE and the exact body bytes on the wire — precisely the two things these
 * tests must pin down. Every accepted connection gets the same canned response; request heads
 * are recorded for assertions.
 */
private class FixtureServer(
    private val status: String = "200 OK",
    private val headers: List<String> = emptyList(),
    private val body: ByteArray,
) : AutoCloseable {
    private val socket = ServerSocket(0, 4, InetAddress.getLoopbackAddress())
    val requests = CopyOnWriteArrayList<String>()

    init {
        thread(isDaemon = true, name = "signing-fixture-server") {
            while (!socket.isClosed) {
                val client = try {
                    socket.accept()
                } catch (_: IOException) {
                    break // socket closed — test is done
                }
                client.use { connection ->
                    val head = StringBuilder()
                    val input = connection.getInputStream()
                    // The client never sends a body: the request ends at the blank line.
                    while (!head.endsWith("\r\n\r\n")) {
                        val byte = input.read()
                        if (byte < 0) break
                        head.append(byte.toInt().toChar())
                    }
                    requests += head.toString()
                    val responseHead = buildString {
                        append("HTTP/1.1 $status\r\n")
                        headers.forEach { header -> append("$header\r\n") }
                        append("Content-Length: ${body.size}\r\n")
                        append("Connection: close\r\n")
                        append("\r\n")
                    }.toByteArray(Charsets.ISO_8859_1)
                    connection.getOutputStream().apply {
                        write(responseHead)
                        write(body)
                        flush()
                    }
                }
            }
        }
    }

    val baseUrl: String get() = "http://127.0.0.1:${socket.localPort}/"

    override fun close() {
        socket.close()
    }
}

/**
 * Wire-level tests of the signing integration in [BrokerClient.listRelays] (SPEC v1 §5.2):
 * bytes discipline (the signature is checked over the raw stream bytes, before any charset
 * decoding), case-insensitive header matching, the non-TLS transport discipline (§6), the
 * loopback dev exemption, and the unsigned non-2xx path. The fixture listens on 127.0.0.1, so
 * verification is forced with the internal [BrokerClient.requireSignatureOnLoopback] switch.
 */
class BrokerClientSigningTest {

    /** Fixed at the vector's server_time, well inside its 30-minute not_after window. */
    private val vectorClock = Clock.fixed(Instant.parse("2026-07-10T00:00:00Z"), ZoneOffset.UTC)

    private fun verifyingClient(baseUrl: String) = BrokerClient(
        baseUrl,
        verifier = RelayListVerifier(listOf(TEST_PUBKEY_HEX), vectorClock),
        requireSignatureOnLoopback = true,
    )

    @Test
    fun `signed response verifies end-to-end over the wire`() {
        FixtureServer(
            headers = listOf(
                "Content-Type: application/json",
                // Lowercase on purpose: HTTP/2/3 lowercase header names, so the client-side
                // match must be case-insensitive (§2.1).
                "x-openrung-relays-signature: $VECTOR_HEADER",
            ),
            body = VECTOR_BODY.toByteArray(),
        ).use { server ->
            val response = runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 1) }
            assertEquals(1, response.count)
            assertEquals("api", response.channel)
            // §6: non-TLS candidates must ask for identity encoding, so no hop recompresses the
            // exact bytes the signature covers (HttpURLConnection adds gzip silently otherwise).
            assertTrue(server.requests.single().contains("Accept-Encoding: identity"))
        }
    }

    @Test
    fun `multibyte body verifies against the exact wire bytes`() {
        // Byte-count != char-count here, so any decode-to-text-and-re-encode with the wrong
        // charset (e.g. Latin-1) breaks the signature — pinning the raw-InputStream discipline.
        // The unknown "fixture_note" key also re-checks the tolerant parser.
        val body =
            """{"count":0,"server_time":"2026-07-10T00:00:00Z","not_after":"2026-07-10T00:30:00Z","key_id":"$TEST_KEY_ID","channel":"api","limit":1,"relays":[],"fixture_note":"日本 – ヘルシンキ"}"""
        val bodyBytes = body.toByteArray()
        val signer = Ed25519Sign(Base64.getDecoder().decode(TEST_SEED_B64))
        val header = "ed25519;$TEST_KEY_ID;" + Base64.getEncoder().encodeToString(signer.sign(bodyBytes))
        FixtureServer(
            headers = listOf(
                "Content-Type: application/json; charset=utf-8",
                "X-OpenRung-Relays-Signature: $header",
            ),
            body = bodyBytes,
        ).use { server ->
            val response = runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 1) }
            assertEquals(0, response.count)
        }
    }

    @Test
    fun `tampered body fails closed as unsigned-invalid`() {
        FixtureServer(
            headers = listOf("Content-Type: application/json", "X-OpenRung-Relays-Signature: $VECTOR_HEADER"),
            // Same length, one flipped digit: the signature no longer covers these bytes.
            body = VECTOR_BODY.replace("\"count\":1", "\"count\":2").toByteArray(),
        ).use { server ->
            val thrown = runCatching {
                runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 1) }
            }.exceptionOrNull()
            assertTrue("expected verification failure, got $thrown", thrown is RelayListVerificationException)
            // §5.2: the surfaced failure names the real problem, not a generic network error.
            assertTrue(thrown?.message.orEmpty().startsWith("unsigned/invalid relay list"))
        }
    }

    @Test
    fun `response without a signature header is a failed candidate`() {
        FixtureServer(
            headers = listOf("Content-Type: application/json"),
            body = VECTOR_BODY.toByteArray(),
        ).use { server ->
            val thrown = runCatching {
                runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 1) }
            }.exceptionOrNull()
            assertTrue("expected verification failure, got $thrown", thrown is RelayListVerificationException)
        }
    }

    @Test
    fun `limit echo mismatch fails over the wire`() {
        // The served body echoes limit=1; asking for 5 must reject it even though the signature
        // itself is valid — the §2.2 variant-steering defence, end to end.
        FixtureServer(
            headers = listOf("Content-Type: application/json", "X-OpenRung-Relays-Signature: $VECTOR_HEADER"),
            body = VECTOR_BODY.toByteArray(),
        ).use { server ->
            val thrown = runCatching {
                runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 5) }
            }.exceptionOrNull()
            assertTrue("expected verification failure, got $thrown", thrown is RelayListVerificationException)
        }
    }

    @Test
    fun `loopback dev brokers stay usable unsigned by default`() {
        // The one signature exemption (§5.2): a loopback broker (adb-reverse dev flow) is served
        // unverified — with the production default requireSignatureOnLoopback=false.
        FixtureServer(
            headers = listOf("Content-Type: application/json"),
            body = VECTOR_BODY.toByteArray(),
        ).use { server ->
            val response = runBlocking { BrokerClient(server.baseUrl).listRelays(limit = 1) }
            assertEquals(1, response.count)
        }
    }

    @Test
    fun `non-2xx responses surface their status and stay unsigned`() {
        // §5.2 step 1: error responses are unsigned by design; they must classify as candidate
        // failures with their HTTP status (429 → rate_limited), never reach the verifier.
        FixtureServer(
            status = "429 Too Many Requests",
            headers = listOf("Content-Type: application/json"),
            body = """{"error":"slow down"}""".toByteArray(),
        ).use { server ->
            val thrown = runCatching {
                runBlocking { verifyingClient(server.baseUrl).listRelays(limit = 1) }
            }.exceptionOrNull()
            assertTrue("expected BrokerHttpException, got $thrown", thrown is BrokerHttpException)
            assertEquals(429, (thrown as BrokerHttpException).status)
            assertTrue(thrown.message.orEmpty().contains("slow down"))
        }
    }

    @Test
    fun `hostIsLoopback exempts loopback literals and localhost only`() {
        assertTrue(BrokerClient.hostIsLoopback("localhost"))
        assertTrue(BrokerClient.hostIsLoopback("LOCALHOST"))
        assertTrue(BrokerClient.hostIsLoopback("127.0.0.1"))
        assertTrue(BrokerClient.hostIsLoopback("127.42.0.7"))
        assertTrue(BrokerClient.hostIsLoopback("[::1]")) // URL.getHost keeps the brackets
        assertFalse(BrokerClient.hostIsLoopback("broker.openrung.org"))
        assertFalse(BrokerClient.hostIsLoopback("54.238.185.205"))
        assertFalse(BrokerClient.hostIsLoopback("[2406:da14:16a4:8400::1]"))
        // Never decided via DNS: a hostname that (maliciously) resolves to 127.0.0.1 is still
        // not loopback — only literals and "localhost" pass, without any lookup.
        assertFalse(BrokerClient.hostIsLoopback("localtest.me"))
        assertFalse(BrokerClient.hostIsLoopback(""))
    }
}
