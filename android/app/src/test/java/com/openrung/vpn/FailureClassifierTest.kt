package com.openrung.vpn

import com.openrung.net.BrokerHttpException
import com.openrung.net.WssTicketStatusException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException

/**
 * Classifier cases that rely only on JVM exception types (no `android.system.*`), so they run under
 * plain JUnit without Robolectric. The errno-based cases live in [FailureClassifierErrnoTest].
 */
class FailureClassifierTest {

    @Test
    fun `null error yields empty token`() {
        assertEquals("", FailureClassifier.classify(null))
    }

    @Test
    fun `socket timeout wrapped in IllegalStateException classifies as timeout`() {
        // Mirrors the real bug: the connect pipeline wraps the root cause in an IllegalStateException,
        // which used to surface on the dashboard as `relay_connect · IllegalStateException`.
        val error = IllegalStateException("Relay 1.2.3.4:443 is not reachable", SocketTimeoutException("connect timed out"))
        assertEquals("timeout", FailureClassifier.classify(error))
    }

    @Test
    fun `unknown host classifies as dns_failure`() {
        assertEquals("dns_failure", FailureClassifier.classify(UnknownHostException("Unable to resolve host")))
    }

    @Test
    fun `dns failure wins over timeout when both are in the chain`() {
        // DNS is the more actionable signal, so a name-lookup that also timed out reports dns_failure.
        val error = SocketTimeoutException("timed out").apply { initCause(UnknownHostException("no address")) }
        assertEquals("dns_failure", FailureClassifier.classify(error))
    }

    @Test
    fun `ssl handshake failure classifies as tls_handshake`() {
        assertEquals("tls_handshake", FailureClassifier.classify(SSLHandshakeException("cert untrusted")))
        assertEquals("tls_handshake", FailureClassifier.classify(SSLException("record header error")))
    }

    @Test
    fun `security exception classifies as permission_denied`() {
        assertEquals("permission_denied", FailureClassifier.classify(SecurityException("VPN permission revoked")))
    }

    @Test
    fun `broker http 429 classifies as rate_limited`() {
        assertEquals("rate_limited", FailureClassifier.classify(BrokerHttpException(429, "broker list relays: too many requests")))
    }

    @Test
    fun `broker http non-429 classifies as http prefix with code`() {
        assertEquals("http_503", FailureClassifier.classify(BrokerHttpException(503, "broker list relays: unavailable")))
        assertEquals("http_500", FailureClassifier.classify(BrokerHttpException(500, "broker list relays: server error")))
    }

    @Test
    fun `WSS ticket status keeps HTTP classification transport scoped`() {
        assertEquals("rate_limited", FailureClassifier.classify(WssTicketStatusException(429, 5_000)))
        assertEquals("http_503", FailureClassifier.classify(WssTicketStatusException(503, null)))
    }

    @Test
    fun `cancellation classifies as cancelled`() {
        assertEquals("cancelled", FailureClassifier.classify(CancellationException("stopped")))
    }

    @Test
    fun `engine start failure classifies as process_exited`() {
        val error = EngineStartException("libbox failed to start", RuntimeException("bad config"))
        assertEquals("process_exited", FailureClassifier.classify(error))
    }

    @Test
    fun `permission wins over engine-exit when a security exception is the engine failure cause`() {
        // A revoked VPN permission surfacing during engine start must classify as permission_denied,
        // not process_exited (permission has higher precedence than engine-exit).
        val error = EngineStartException("engine failed", SecurityException("permission denied"))
        assertEquals("permission_denied", FailureClassifier.classify(error))
    }

    @Test
    fun `each relay-selection sentinel maps to its token`() {
        assertEquals("no_relays_available", FailureClassifier.classify(RelaySelectionException.NoRelaysAvailable("none")))
        assertEquals("relay_not_in_list", FailureClassifier.classify(RelaySelectionException.RelayNotInList("gone")))
        assertEquals("no_relay_in_country", FailureClassifier.classify(RelaySelectionException.NoRelayInCountry("no relay in Peru")))
        assertEquals("no_usable_relay", FailureClassifier.classify(RelaySelectionException.NoUsableRelay("none usable")))
    }

    @Test
    fun `unrecognized error classifies as unknown`() {
        assertEquals("unknown", FailureClassifier.classify(RuntimeException("boom")))
        // A generic IOException (e.g. the "no broker endpoints reachable" fallback) is honestly unknown.
        assertEquals("unknown", FailureClassifier.classify(IOException("no broker endpoints reachable")))
    }

    @Test
    fun `detail reports the root cause message`() {
        val error = IllegalStateException("all relay attempts failed", SocketTimeoutException("connect timed out"))
        assertEquals("connect timed out", FailureClassifier.detail(error))
    }

    @Test
    fun `detail is empty for a null error`() {
        assertEquals("", FailureClassifier.detail(null))
    }

    @Test
    fun `detail truncates on a UTF-8 character boundary`() {
        // 254 ASCII bytes + a 4-byte emoji = 258 bytes; a naive 256-byte cut would split the emoji.
        val base = "a".repeat(254)
        val message = base + "😀" // U+1F600 😀, F0 9F 98 80
        val truncated = FailureClassifier.truncateToBytes(message)

        assertEquals(base, truncated)
        assertTrue("must not exceed 256 UTF-8 bytes", truncated.toByteArray(Charsets.UTF_8).size <= 256)
        assertFalse("must not contain a replacement char from a split sequence", truncated.contains('�'))
    }

    @Test
    fun `truncate leaves values within the limit untouched`() {
        val short = "connect timed out"
        assertEquals(short, FailureClassifier.truncateToBytes(short))

        val exactly256 = "a".repeat(256)
        assertEquals(exactly256, FailureClassifier.truncateToBytes(exactly256))

        val over = "a".repeat(300)
        assertEquals(256, FailureClassifier.truncateToBytes(over).toByteArray(Charsets.UTF_8).size)
    }
}
