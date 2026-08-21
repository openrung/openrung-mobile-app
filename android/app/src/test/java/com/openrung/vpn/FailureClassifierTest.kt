package com.openrung.vpn

import com.openrung.net.BrokerNativeFailure
import com.openrung.net.BrokerNativeFailureKind
import com.openrung.net.WssTicketStatusException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.IOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLException
import javax.net.ssl.SSLHandshakeException

/**
 * Adapter cases that rely only on JVM exception types (no `android.system.*`), so they run under
 * plain JUnit without Robolectric. The errno-based cases live in [FailureClassifierErrnoTest].
 *
 * These tests pin the extraction half of the classifier — platform exception chain → binding
 * input facts. The facts→token half (the ladder, its precedence, and the broker-kind projection)
 * lives in Go and is pinned by `android/punchbridge/failure_binding_test.go`, which runs the same
 * input shapes through the real binding.
 */
class FailureClassifierTest {

    private fun facts(error: Throwable): JsonObject =
        Json.parseToJsonElement(FailureClassifier.describeFailure(error)).jsonObject

    @Test
    fun `null error yields empty token without touching the binding`() {
        assertEquals("", FailureClassifier.classify(null))
    }

    @Test
    fun `socket timeout wrapped in IllegalStateException is described on its merits`() {
        // Mirrors the real bug: the connect pipeline wraps the root cause in an IllegalStateException,
        // which used to surface on the dashboard as `relay_connect · IllegalStateException`.
        val error = IllegalStateException("Relay 1.2.3.4:443 is not reachable", SocketTimeoutException("connect timed out"))
        assertEquals(buildJsonObject { put("timeout", true) }, facts(error))
    }

    @Test
    fun `unknown host describes a DNS failure`() {
        assertEquals(
            buildJsonObject { put("dns", true) },
            facts(UnknownHostException("Unable to resolve host")),
        )
    }

    @Test
    fun `a chain carrying DNS and timeout reports both facts`() {
        // The shared ladder keeps DNS ahead of timeout (the more actionable signal); the adapter's
        // job is only to report both. The winner is pinned by the Go binding tests.
        val error = SocketTimeoutException("timed out").apply { initCause(UnknownHostException("no address")) }
        assertEquals(
            buildJsonObject {
                put("dns", true)
                put("timeout", true)
            },
            facts(error),
        )
    }

    @Test
    fun `ssl failures describe a TLS failure`() {
        val expected = buildJsonObject { put("tls", true) }
        assertEquals(expected, facts(SSLHandshakeException("cert untrusted")))
        assertEquals(expected, facts(SSLException("record header error")))
    }

    @Test
    fun `security exception describes an OS permission denial`() {
        assertEquals(
            buildJsonObject { put("permission_denied", true) },
            facts(SecurityException("VPN permission revoked")),
        )
    }

    @Test
    fun `WSS ticket status carries its HTTP status`() {
        assertEquals(
            buildJsonObject { put("http_status", 429) },
            facts(WssTicketStatusException(429, 5_000)),
        )
        assertEquals(
            buildJsonObject { put("http_status", 503) },
            facts(WssTicketStatusException(503, null)),
        )
    }

    @Test
    fun `every native binding kind passes through with its status`() {
        // The kind→token projection that classifyNativeFailure used to own is now the shared
        // classifier's; the adapter forwards the bounded kind string verbatim.
        BrokerNativeFailureKind.entries.forEach { kind ->
            val status = if (kind == BrokerNativeFailureKind.HTTP_STATUS) 503 else null
            val error = BrokerNativeFailure(kind = kind, httpStatus = status, message = "bounded native failure")
            assertEquals(
                "$kind",
                buildJsonObject {
                    put("broker_kind", kind.value)
                    status?.let { put("http_status", it) }
                },
                facts(error),
            )
        }
    }

    @Test
    fun `a broker failure's status outranks a ticket status deeper in the chain`() {
        // One http_status field cannot report two statuses; the adapter keeps the old ladder's
        // broker-before-ticket order by deferring to the broker failure's own status.
        val error = BrokerNativeFailure(
            kind = BrokerNativeFailureKind.HTTP_STATUS,
            httpStatus = 502,
            message = "broker failure",
            cause = WssTicketStatusException(503, null),
        )
        assertEquals(
            buildJsonObject {
                put("broker_kind", "http_status")
                put("http_status", 502)
            },
            facts(error),
        )
    }

    @Test
    fun `cancellation describes local intent`() {
        assertEquals(
            buildJsonObject { put("cancelled", true) },
            facts(CancellationException("stopped")),
        )
    }

    @Test
    fun `engine start failure describes an engine exit`() {
        val error = EngineStartException("libbox failed to start", RuntimeException("bad config"))
        assertEquals(buildJsonObject { put("process_exited", true) }, facts(error))
    }

    @Test
    fun `a security exception inside an engine failure reports both facts`() {
        // A revoked VPN permission surfacing during engine start must classify as permission_denied,
        // not process_exited; the adapter reports both facts and the shared ladder keeps permission
        // ahead of engine-exit (pinned by the Go binding tests).
        val error = EngineStartException("engine failed", SecurityException("permission denied"))
        assertEquals(
            buildJsonObject {
                put("permission_denied", true)
                put("process_exited", true)
            },
            facts(error),
        )
    }

    @Test
    fun `each relay-selection sentinel maps to its input token`() {
        fun selection(token: String): JsonObject = buildJsonObject { put("selection", token) }
        assertEquals(selection("no_relays_available"), facts(RelaySelectionException.NoRelaysAvailable("none")))
        assertEquals(selection("relay_not_in_list"), facts(RelaySelectionException.RelayNotInList("gone")))
        assertEquals(selection("no_relay_in_country"), facts(RelaySelectionException.NoRelayInCountry("no relay in Peru")))
        assertEquals(selection("no_usable_relay"), facts(RelaySelectionException.NoUsableRelay("none usable")))
    }

    @Test
    fun `unrecognized errors describe no facts`() {
        // The binding classifies an empty description as the bounded "unknown" residual.
        assertEquals(buildJsonObject {}, facts(RuntimeException("boom")))
        // A generic IOException (e.g. the "no broker endpoints reachable" fallback) is honestly fact-free.
        assertEquals(buildJsonObject {}, facts(IOException("no broker endpoints reachable")))
    }

    @Test
    fun `detail message is the root cause's`() {
        val error = IllegalStateException("all relay attempts failed", SocketTimeoutException("connect timed out"))
        assertEquals("connect timed out", FailureClassifier.detailMessage(error))
    }

    @Test
    fun `detail message falls back to the outermost message when the root's is blank`() {
        val error = IllegalStateException("all relay attempts failed", RuntimeException())
        assertEquals("all relay attempts failed", FailureClassifier.detailMessage(error))
    }

    @Test
    fun `detail is empty for a null error without touching the binding`() {
        assertEquals("", FailureClassifier.detail(null))
        assertNull(FailureClassifier.detailMessage(null))
    }
}
