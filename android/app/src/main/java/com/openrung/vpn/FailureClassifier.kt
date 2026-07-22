package com.openrung.vpn

import android.system.ErrnoException
import android.system.OsConstants
import com.openrung.net.BrokerHttpException
import com.openrung.net.WssTicketStatusException
import java.io.InterruptedIOException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLException

/**
 * Classifies a connection failure into a stable, lowercase snake_case reason token shared with the
 * OpenRung Go clients (desktop/CLI) and honored by the broker's "Failure reasons" dashboard.
 *
 * The token set and the classification precedence mirror the Go classifier
 * (`internal/clienttelemetry/classify.go` in the sibling `openrung` repo):
 * cancellation → relay-selection sentinels → broker HTTP status → socket errno →
 * DNS (before generic timeout, the more actionable signal) → TLS → permission →
 * engine-exit → generic timeout → `unknown`.
 *
 * The entire `cause` chain is inspected, so a real root cause (e.g. a [SocketTimeoutException]
 * wrapped in an `IllegalStateException` by the connect pipeline) is classified on its merits rather
 * than reported as the generic wrapper class — which is why the dashboard used to show
 * `relay_connect · IllegalStateException`.
 */
object FailureClassifier {
    private const val MAX_DETAIL_BYTES = 256

    /** Returns the reason token for [error], or `""` when [error] is null. */
    fun classify(error: Throwable?): String {
        if (error == null) return ""
        val chain = causeChain(error)

        // (1) cancellation (user stop / coroutine cancellation)
        if (chain.any { it is CancellationException }) return "cancelled"

        // (2) app relay-selection sentinels
        chain.firstNotNullOfOrNull { it as? RelaySelectionException }?.let {
            return when (it) {
                is RelaySelectionException.NoRelaysAvailable -> "no_relays_available"
                is RelaySelectionException.RelayNotInList -> "relay_not_in_list"
                is RelaySelectionException.NoRelayInCountry -> "no_relay_in_country"
                is RelaySelectionException.NoUsableRelay -> "no_usable_relay"
            }
        }

        // (3) broker HTTP status (429 → rate_limited, else http_<code>)
        chain.firstNotNullOfOrNull { it as? BrokerHttpException }?.let {
            return if (it.status == 429) "rate_limited" else "http_${it.status}"
        }
        chain.firstNotNullOfOrNull { it as? WssTicketStatusException }?.let {
            return if (it.status == 429) "rate_limited" else "http_${it.status}"
        }

        // (4) socket errno — refused / reset / unreachable. EACCES/EPERM and ETIMEDOUT are handled
        // later (permission / timeout) to match the Go errno switch, which only maps these three.
        val errno = chain.firstNotNullOfOrNull { it as? ErrnoException }
        errno?.let {
            when (it.errno) {
                OsConstants.ECONNREFUSED -> return "connection_refused"
                OsConstants.ECONNRESET -> return "connection_reset"
                OsConstants.ENETUNREACH, OsConstants.EHOSTUNREACH -> return "network_unreachable"
            }
        }

        // (5) DNS — before generic timeout, so a name-lookup timeout reports as dns_failure.
        if (chain.any { it is UnknownHostException }) return "dns_failure"

        // (6) TLS / SSL handshake or certificate failure (SSLHandshakeException is an SSLException).
        if (chain.any { it is SSLException }) return "tls_handshake"

        // (7) OS-denied permission (revoked VPN consent, EACCES/EPERM).
        if (chain.any { it is SecurityException }) return "permission_denied"
        errno?.let {
            if (it.errno == OsConstants.EACCES || it.errno == OsConstants.EPERM) {
                return "permission_denied"
            }
        }

        // (8) embedded proxy engine failed to start / stopped unexpectedly.
        if (chain.any { it is EngineStartException }) return "process_exited"

        // (9) generic timeout — only after the typed checks above.
        errno?.let { if (it.errno == OsConstants.ETIMEDOUT) return "timeout" }
        // SocketTimeoutException is an InterruptedIOException; the base type also covers a bare
        // connect/read timeout raised without the more specific subclass.
        if (chain.any { it is InterruptedIOException }) return "timeout"

        return "unknown"
    }

    /**
     * The root cause's message (falling back to the outermost error's), truncated to fit the
     * broker's 256-UTF-8-byte attribute limit. Returns `""` when there is no usable message.
     */
    fun detail(error: Throwable?): String {
        if (error == null) return ""
        val chain = causeChain(error)
        val message = chain.last().message?.takeIf { it.isNotBlank() }
            ?: error.message?.takeIf { it.isNotBlank() }
            ?: return ""
        return truncateToBytes(message, MAX_DETAIL_BYTES)
    }

    /**
     * Truncates [value] to at most [maxBytes] UTF-8 bytes without splitting a multi-byte character:
     * the boundary is backed off past any UTF-8 continuation byte (`0b10xxxxxx`) so the result is
     * always decodable. The broker rejects attribute values whose UTF-8 encoding exceeds 256 bytes.
     */
    internal fun truncateToBytes(value: String, maxBytes: Int = MAX_DETAIL_BYTES): String {
        if (value.isEmpty()) return value
        val bytes = value.toByteArray(Charsets.UTF_8)
        if (bytes.size <= maxBytes) return value
        var end = maxBytes
        while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
        return String(bytes, 0, end, Charsets.UTF_8)
    }

    /** Self (plus every distinct `cause`) from the outermost error down to the root, cycle-safe. */
    private fun causeChain(error: Throwable): List<Throwable> {
        val chain = ArrayList<Throwable>()
        val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        var current: Throwable? = error
        while (current != null && seen.add(current)) {
            chain.add(current)
            current = current.cause
        }
        return chain
    }
}

/**
 * Relay-selection failures raised by the connect pipeline. A typed hierarchy (rather than a bare
 * `IllegalStateException` from `check(...)`) lets [FailureClassifier] map each to its stable reason
 * token without matching on the user-facing message text.
 */
sealed class RelaySelectionException(message: String) : Exception(message) {
    /** Broker returned an empty / all-unusable relay list. */
    class NoRelaysAvailable(message: String) : RelaySelectionException(message)

    /** A targeted exact relay id was not present in the list. */
    class RelayNotInList(message: String) : RelaySelectionException(message)

    /** A targeted country had no usable relay. */
    class NoRelayInCountry(message: String) : RelaySelectionException(message)

    /** No relay passed the usability filter (generic). */
    class NoUsableRelay(message: String) : RelaySelectionException(message)
}

/**
 * Raised when the embedded proxy engine (libbox/sing-box) fails to start or stops unexpectedly.
 * Maps to `process_exited` for parity with the Go clients, which run sing-box as a subprocess.
 * The originating error is kept as the [cause] so a higher-precedence signal in the chain (a
 * revoked-permission [SecurityException], a socket errno, …) still wins over `process_exited`.
 */
class EngineStartException(message: String?, cause: Throwable?) : Exception(message, cause)
