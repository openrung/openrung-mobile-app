package com.openrung.telemetry

/**
 * Per-application rate limiter for `application_connection` events. The broker folds these
 * events into an hourly per-application flow total (summing each event's `connection_count`,
 * openrung PR #88) and discards the rest of the payload, so repeated events inside the normal
 * count range are pure transmit overhead. Callers record every tunneled flow; at
 * normally one event per application per [windowMs] passes through, carrying the number of flows
 * observed since the previous emitted event. Totals above the broker's per-event ceiling are
 * split into lossless chunks, and [drainPending] flushes the still-suppressed remainder when the
 * session ends.
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
     * Records one flow for [packageName]. Returns the flow counts to report (this flow plus any
     * suppressed since the last emitted event, split into chunks no larger than
     * [MAX_REPORTED_FLOWS]) when the window expires, or an empty list while the flow remains
     * inside the current window.
     */
    @Synchronized
    fun recordFlow(packageName: String, uid: Int): List<Long> {
        val now = elapsedMs()
        val window = windows[packageName]
        if (window != null && now - window.emittedAtMs < windowMs) {
            window.suppressedFlows++
            window.uid = uid
            return emptyList()
        }
        val count = (window?.suppressedFlows ?: 0L) + 1L
        windows[packageName] = Window(emittedAtMs = now, suppressedFlows = 0L, uid = uid)
        return count.toReportedChunks()
    }

    /**
     * Returns every application's still-suppressed flow count, split into chunks no larger than
     * [MAX_REPORTED_FLOWS], and forgets all windows. Called when a session ends or is replaced so
     * the broker's summed totals keep each window's tail instead of losing it to [reset]; counts
     * pending at process death or displaced from the bounded outbox are still lost
     * (dashboard-grade approximation).
     */
    @Synchronized
    fun drainPending(): List<PendingFlows> = buildList {
        windows.forEach { (packageName, window) ->
            window.suppressedFlows.toReportedChunks().forEach { flows ->
                add(PendingFlows(packageName, window.uid, flows))
            }
        }
        windows.clear()
    }

    private fun Long.toReportedChunks(): List<Long> {
        if (this <= 0L) return emptyList()
        var remaining = this
        return buildList {
            while (remaining > 0L) {
                val chunk = remaining.coerceAtMost(MAX_REPORTED_FLOWS)
                add(chunk)
                remaining -= chunk
            }
        }
    }

    companion object {
        /**
         * The broker treats a `connection_count` above its own 100,000 per-app-per-batch cap as a
         * malformed value and falls back to weight 1 (openrung PR #88), so every emitted chunk
         * stays at or below that limit. TelemetryManager also separates chunks for the same app
         * across upload batches so the broker can count all of them.
         */
        const val MAX_REPORTED_FLOWS = 100_000L
    }
}
