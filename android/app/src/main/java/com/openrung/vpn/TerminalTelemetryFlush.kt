package com.openrung.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Makes one bounded best-effort attempt without converting caller cancellation into success.
 * Upload failures and the local timeout leave the durable outbox intact for a later session.
 */
internal suspend fun bestEffortTelemetryFlush(
    brokerUrl: String,
    timeoutMillis: Long,
    flush: suspend (String) -> Unit,
) {
    require(timeoutMillis > 0) { "telemetry flush timeout must be positive" }
    try {
        withTimeoutOrNull(timeoutMillis) { flush(brokerUrl) }
    } catch (_: CancellationException) {
        // Propagate only real caller cancellation. The native transport verifies the caller's
        // cancellation state before mapping its own "cancelled" kind, but this terminal path
        // keeps its own guard: any dependency minting CancellationException while this coroutine
        // is live would otherwise skip a terminal caller's stop and leave the service running.
        currentCoroutineContext().ensureActive()
    } catch (_: Throwable) {
        // Best effort: the outbox commits only successful uploads and will retry later.
    }
}

/**
 * Keeps the service alive until its final telemetry attempt completes or times out. The final
 * cancellation check prevents a superseded epoch from stopping the service owned by its successor.
 */
internal suspend fun flushTelemetryBeforeStop(
    brokerUrl: String,
    timeoutMillis: Long,
    flush: suspend (String) -> Unit,
    stop: () -> Unit,
) {
    bestEffortTelemetryFlush(brokerUrl, timeoutMillis, flush)
    currentCoroutineContext().ensureActive()
    stop()
}
