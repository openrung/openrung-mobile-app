package com.openrung.net

import android.os.SystemClock
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeout
import java.io.IOException
import java.net.SocketTimeoutException
import java.time.DateTimeException
import java.time.Instant
import kotlin.math.min

/** One short-lived credential bound by the broker to an exact relay and signed WSS front. */
data class WssSessionTicket(
    /** Opaque bearer value. It must never be logged or placed in a URL. */
    val ticket: String,
    val expiresAt: Instant,
    /** Exact front URL echoed by the broker; the caller compares it byte-for-byte. */
    val url: String,
) {
    /** Redact both sensitive values from data-class logging and debugger string surfaces. */
    override fun toString(): String =
        "WssSessionTicket(ticket=<redacted>, expiresAt=$expiresAt, url=<redacted>)"
}

/**
 * Typed status projection used by the existing bounded retry policy. Native error detail is kept
 * only as a bounded cause and neither the ticket nor bound URL is included in this message.
 */
class WssTicketStatusException(
    val status: Int,
    val retryAfterMillis: Long?,
    cause: Throwable? = null,
) : IOException("broker WSS ticket request failed with HTTP status $status", cause)

/** Bounds one complete broker-front failover attempt, including its optional retry round. */
internal data class WssTicketPolicy(
    val totalDeadlineMillis: Long = 15_000,
    val perAttemptMillis: Long = 5_000,
    val defaultRetryAfterMillis: Long = 10_000,
    val maxRetryAfterMillis: Long = 30_000,
) {
    init {
        require(totalDeadlineMillis > 0) { "WSS ticket total deadline must be positive" }
        require(perAttemptMillis > 0) { "WSS ticket attempt deadline must be positive" }
        require(defaultRetryAfterMillis > 0) { "WSS ticket default retry delay must be positive" }
        require(maxRetryAfterMillis > 0) { "WSS ticket maximum retry delay must be positive" }
    }
}

internal typealias WssTicketAttempt = suspend (
    brokerUrl: String,
    relayId: String,
    frontId: String,
    clientId: String?,
    sessionId: String?,
    timeoutMillis: Long,
) -> WssSessionTicket

/**
 * WSS-ticket policy stays in Kotlin; only each individual request is delegated to brokerapi.
 *
 * Front ordering, one total budget, one optional retry round, first-error semantics, and 429/503
 * eligibility are intentionally unchanged.
 */
object WssTicketClient {
    suspend fun requestWithFailover(
        brokerUrls: List<String>,
        relayId: String,
        frontId: String,
        clientId: String? = null,
        sessionId: String? = null,
    ): WssSessionTicket = requestWithFailover(
        brokerUrls = brokerUrls,
        relayId = relayId,
        frontId = frontId,
        clientId = clientId,
        sessionId = sessionId,
        policy = WssTicketPolicy(),
        elapsedRealtimeMillis = SystemClock::elapsedRealtime,
        wait = { delay(it) },
        attempt = { brokerUrl, requestedRelayId, requestedFrontId, requestedClientId, requestedSessionId, timeout ->
            requestOnce(
                brokerUrl = brokerUrl,
                relayId = requestedRelayId,
                frontId = requestedFrontId,
                clientId = requestedClientId,
                sessionId = requestedSessionId,
                timeoutMillis = timeout,
            )
        },
    )

    /** Injectable pure orchestration core retained for hostless policy tests. */
    internal suspend fun requestWithFailover(
        brokerUrls: List<String>,
        relayId: String,
        frontId: String,
        clientId: String?,
        sessionId: String?,
        policy: WssTicketPolicy,
        elapsedRealtimeMillis: () -> Long,
        wait: suspend (Long) -> Unit,
        attempt: WssTicketAttempt,
    ): WssSessionTicket {
        require(relayId.isNotBlank()) { "WSS ticket relay_id is required" }
        require(frontId.isNotBlank()) { "WSS ticket front_id is required" }
        val fronts = brokerUrls.map(String::trim).filter(String::isNotEmpty).distinct()
        require(fronts.isNotEmpty()) { "no broker fronts configured for WSS ticket" }

        val startedAt = elapsedRealtimeMillis()
        val deadline = saturatedAdd(startedAt, policy.totalDeadlineMillis)
        var firstFailure: Throwable? = null
        var retryDelayMillis: Long? = null

        for (round in 0..1) {
            for (brokerUrl in fronts) {
                currentCoroutineContext().ensureActive()
                val remainingMillis = remainingMillis(deadline, elapsedRealtimeMillis())
                if (remainingMillis <= 0) throw firstFailure ?: ticketDeadlineExceeded()
                val attemptMillis = min(policy.perAttemptMillis, remainingMillis)

                val failure = try {
                    return withTimeout(attemptMillis) {
                        attempt(
                            brokerUrl,
                            relayId,
                            frontId,
                            clientId,
                            sessionId,
                            attemptMillis,
                        )
                    }
                } catch (_: TimeoutCancellationException) {
                    SocketTimeoutException("WSS ticket broker attempt timed out")
                } catch (error: CancellationException) {
                    // Caller cancellation is exceptional and must never mint a ticket on a later
                    // front. The native runner has already dispatched Close before this propagates.
                    throw error
                } catch (error: BrokerNativeFailure) {
                    // These are Android artifact/model/configuration failures, not evidence that
                    // another remote front is reachable. Abort without consuming another ticket.
                    if (error.isLocalPlatformFailure) throw error
                    error
                } catch (error: LinkageError) {
                    throw unavailableNativeBrokerFailure(error)
                } catch (error: Throwable) {
                    if (error.hasLocalNativeBrokerFailure()) throw error
                    error
                }

                if (firstFailure == null) firstFailure = failure
                if (round == 0) {
                    retryDelayFor(failure, policy)?.let { candidateDelay ->
                        retryDelayMillis = maxOf(retryDelayMillis ?: 0, candidateDelay)
                    }
                }
            }

            if (round == 1) break
            val retryDelay = retryDelayMillis ?: throw checkNotNull(firstFailure)
            val remainingMillis = remainingMillis(deadline, elapsedRealtimeMillis())
            // A wait that consumes the whole remaining budget cannot leave time for another request.
            if (retryDelay >= remainingMillis) throw checkNotNull(firstFailure)
            wait(retryDelay)
            currentCoroutineContext().ensureActive()
            if (remainingMillis(deadline, elapsedRealtimeMillis()) <= 0) {
                throw checkNotNull(firstFailure)
            }
        }

        throw firstFailure ?: ticketDeadlineExceeded()
    }

    /**
     * Performs one synchronous native RequestWSSTicket under the caller's surrounding timeout.
     * Every invocation creates and closes a fresh operation.
     */
    internal suspend fun requestOnce(
        brokerUrl: String,
        relayId: String,
        frontId: String,
        clientId: String? = null,
        sessionId: String? = null,
        timeoutMillis: Long = WssTicketPolicy().perAttemptMillis,
        operationFactory: NativeBrokerOperationFactory = NativeBrokerTransport.operationFactory,
    ): WssSessionTicket {
        require(relayId.isNotBlank()) { "WSS ticket relay_id is required" }
        require(frontId.isNotBlank()) { "WSS ticket front_id is required" }
        require(timeoutMillis > 0) { "WSS ticket timeout must be positive" }

        val native = runNativeBrokerOperation(operationFactory) { operation ->
            operation.requestWSSTicket(
                brokerUrl = brokerUrl,
                relayId = relayId,
                frontId = frontId,
                clientId = clientId.orEmpty(),
                sessionId = sessionId.orEmpty(),
            )
        }
        val result = try {
            requireNativeBrokerSuccess(native, "native WSS ticket request")
        } catch (failure: BrokerNativeFailure) {
            if (failure.isLocalPlatformFailure) throw failure
            val status = failure.httpStatus
            if (status != null) {
                throw WssTicketStatusException(
                    status = status,
                    retryAfterMillis = failure.retryAfterMillis,
                    cause = failure,
                )
            }
            throw failure
        }

        val expiresAt = try {
            Instant.ofEpochMilli(result.expiresAtMillis)
        } catch (_: DateTimeException) {
            throw BrokerNativeFailure(
                kind = BrokerNativeFailureKind.DECODE,
                message = "native WSS ticket result has an invalid expiry",
            )
        }
        return WssSessionTicket(
            ticket = result.ticket,
            expiresAt = expiresAt,
            url = result.url,
        )
    }

    private fun retryDelayFor(error: Throwable, policy: WssTicketPolicy): Long? {
        val statusError = error as? WssTicketStatusException ?: return null
        if (statusError.status != 429 && statusError.status != 503) return null
        // Zero/negative native values were projected to null; absent hints use the existing delay.
        val requested = statusError.retryAfterMillis?.takeIf { it > 0 }
            ?: policy.defaultRetryAfterMillis
        return requested.coerceAtMost(policy.maxRetryAfterMillis)
    }

    private fun saturatedAdd(value: Long, increment: Long): Long =
        if (value > Long.MAX_VALUE - increment) Long.MAX_VALUE else value + increment

    private fun remainingMillis(deadline: Long, now: Long): Long =
        if (now >= deadline) 0 else deadline - now

    private fun ticketDeadlineExceeded(): SocketTimeoutException =
        SocketTimeoutException("WSS ticket request deadline exceeded")

    private fun Throwable.hasLocalNativeBrokerFailure(): Boolean {
        val seen = HashSet<Throwable>()
        var current: Throwable? = this
        while (current != null && seen.add(current)) {
            if (current is BrokerNativeFailure && current.isLocalPlatformFailure) return true
            current = current.cause
        }
        return false
    }
}
