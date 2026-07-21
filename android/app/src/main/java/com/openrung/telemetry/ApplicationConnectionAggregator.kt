package com.openrung.telemetry

/**
 * Per-application rate limiter for `application_connection` events. The broker folds these
 * events into an hourly per-application flow total (summing each event's `connection_count`,
 * openrung PR #88) and discards the rest of the payload, so more than one event per
 * application per window is pure transmit overhead. Callers record every tunneled flow; at
 * most one flow per application per [windowMs] passes through, carrying the number of flows
 * observed since the previous emitted event, and [drainPending] flushes the still-suppressed
 * remainder when the session ends.
 */
internal class ApplicationConnectionAggregator(
    private val windowMs: Long,
    private val elapsedMs: () -> Long,
) {
    internal data class PendingFlows(val packageName: String, val uid: Int, val flows: Long)

    private class Window(var emittedAtMs: Long, var suppressedFlows: Long, var uid: Int)

    private val windows = HashMap<String, Window>()

    /**
     * Forgets all windows and suppressed counts. Called at session start so a count emitted
     * mid-session can never carry flows that happened under a previous session's relay/geo.
     */
    @Synchronized
    fun reset() {
        windows.clear()
    }

    /**
     * Records one flow for [packageName]. Returns the flow count to report (this flow plus any
     * suppressed since the last emitted event, clamped to [MAX_REPORTED_FLOWS]) when an event
     * should be emitted, or null when the flow falls inside the current window and must not
     * produce an event.
     */
    @Synchronized
    fun recordFlow(packageName: String, uid: Int): Long? {
        val now = elapsedMs()
        val window = windows[packageName]
        if (window != null && now - window.emittedAtMs < windowMs) {
            window.suppressedFlows++
            window.uid = uid
            return null
        }
        val count = (window?.suppressedFlows ?: 0L) + 1L
        windows[packageName] = Window(emittedAtMs = now, suppressedFlows = 0L, uid = uid)
        return count.coerceAtMost(MAX_REPORTED_FLOWS)
    }

    /**
     * Returns every application's still-suppressed flow count (clamped to
     * [MAX_REPORTED_FLOWS]) and forgets all windows. Called when a session ends or is replaced
     * so the broker's summed totals keep each window's tail instead of losing it to [reset];
     * counts pending at process death are still lost (dashboard-grade approximation).
     */
    @Synchronized
    fun drainPending(): List<PendingFlows> {
        val pending = windows.mapNotNull { (packageName, window) ->
            if (window.suppressedFlows > 0) {
                PendingFlows(packageName, window.uid, window.suppressedFlows.coerceAtMost(MAX_REPORTED_FLOWS))
            } else {
                null
            }
        }
        windows.clear()
        return pending
    }

    companion object {
        /**
         * The broker treats a `connection_count` above its own 100,000 per-app-per-batch cap
         * as a malformed value and falls back to weight 1 (openrung PR #88), so clamp here
         * rather than tripping that cliff.
         */
        const val MAX_REPORTED_FLOWS = 100_000L
    }
}
