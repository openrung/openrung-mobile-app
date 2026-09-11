package com.openrung.vpn

import android.system.ErrnoException
import com.openrung.net.BrokerNativeFailure
import com.openrung.net.WssTicketStatusException
import io.nekohasekai.libbox.Libbox
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.InterruptedIOException
import java.net.UnknownHostException
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLException

/**
 * Platform adapter for the shared failure classifier: translates an Android exception chain into
 * the input facts of the libbox binding's `OpenRungClassifyFailure`, whose token comes from the
 * one Go classifier every OpenRung client runs (`connectcore/clienttelemetry` in the sibling
 * `openrung` repo — the ladder this file used to hand-copy). This file no longer chooses tokens
 * or orders rungs; it only says which platform exception types express which facts.
 *
 * The entire `cause` chain is inspected, so a real root cause (e.g. a `SocketTimeoutException`
 * wrapped in an `IllegalStateException` by the connect pipeline) is described on its merits rather
 * than reported as the generic wrapper class — which is why the dashboard used to show
 * `relay_connect · IllegalStateException`. A chain can express several facts at once (a
 * revoked-permission [SecurityException] inside an [EngineStartException]); the shared ladder,
 * not this adapter, decides which one wins.
 *
 * The extraction ([describeFailure], [detailMessage]) is pure JVM so the contract-vector suite can
 * pin it without the native library; the facts→token half runs in `android/punchbridge`'s Go tests
 * against the same checked-in inputs (`testdata/classification-binding-inputs.json`).
 */
object FailureClassifier {

    /** Returns the reason token for [error], or `""` when [error] is null. */
    fun classify(error: Throwable?): String {
        if (error == null) return ""
        return Libbox.openRungClassifyFailure(describeFailure(error))
    }

    /**
     * The binding input for [error]: one JSON object of extracted facts. Values that need a chain
     * position take the first match (an errno, a broker failure); presence facts take any match.
     * The WSS-ticket status defers to a native broker failure's, preserving the old ladder's
     * broker-before-ticket rung order — a chain never carries both in practice, but one
     * `http_status` field cannot report two statuses.
     */
    internal fun describeFailure(error: Throwable): String {
        val chain = causeChain(error)
        val brokerFailure = chain.firstNotNullOfOrNull { it as? BrokerNativeFailure }
        return buildJsonObject {
            if (chain.any { it is CancellationException }) put("cancelled", true)
            chain.firstNotNullOfOrNull { it as? RelaySelectionException }?.let {
                put(
                    "selection",
                    when (it) {
                        is RelaySelectionException.NoRelaysAvailable -> "no_relays_available"
                        is RelaySelectionException.RelayNotInList -> "relay_not_in_list"
                        is RelaySelectionException.NoRelayInCountry -> "no_relay_in_country"
                        is RelaySelectionException.NoUsableRelay -> "no_usable_relay"
                    },
                )
            }
            brokerFailure?.let {
                // The bounded binding kind passes through verbatim; the shared classifier owns
                // the kind→token projection that classifyNativeFailure used to hand-copy here.
                put("broker_kind", it.kind.value)
                it.httpStatus?.let { status -> put("http_status", status) }
            }
            if (brokerFailure == null) {
                chain.firstNotNullOfOrNull { it as? WssTicketStatusException }?.let {
                    put("http_status", it.status)
                }
            }
            chain.firstNotNullOfOrNull { it as? ErrnoException }?.let { put("errno", it.errno) }
            if (chain.any { it is UnknownHostException }) put("dns", true)
            // SSLHandshakeException is an SSLException, so both handshake and certificate
            // failures match.
            if (chain.any { it is SSLException }) put("tls", true)
            // OS-denied permission (revoked VPN consent). EACCES/EPERM arrive as the errno above.
            if (chain.any { it is SecurityException }) put("permission_denied", true)
            if (chain.any { it is EngineStartException }) put("process_exited", true)
            // SocketTimeoutException is an InterruptedIOException; the base type also covers a
            // bare connect/read timeout raised without the more specific subclass.
            if (chain.any { it is InterruptedIOException }) put("timeout", true)
        }.toString()
    }

    /**
     * The root cause's message (falling back to the outermost error's), bounded by the binding to
     * the broker's 256-UTF-8-byte attribute limit. Returns `""` when there is no usable message.
     */
    fun detail(error: Throwable?): String {
        val message = detailMessage(error) ?: return ""
        return Libbox.openRungFailureDetail(message)
    }

    /** The message [detail] reports, before the binding bounds it; null when there is none. */
    internal fun detailMessage(error: Throwable?): String? {
        if (error == null) return null
        val chain = causeChain(error)
        return chain.last().message?.takeIf { it.isNotBlank() }
            ?: error.message?.takeIf { it.isNotBlank() }
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
