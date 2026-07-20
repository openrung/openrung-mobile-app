package com.openrung.telemetry

/**
 * Per-application rate limiter for `application_connection` events. The broker folds these
 * events into an hourly per-application count and discards the rest of the payload, so more
 * than one event per application per window is pure transmit overhead. Callers record every
 * tunneled flow; at most one flow per application per [windowMs] passes through, carrying the
 * number of flows observed since the previous emitted event.
 */
internal class ApplicationConnectionAggregator(
    private val windowMs: Long,
    private val elapsedMs: () -> Long,
) {
    private class Window(var emittedAtMs: Long, var suppressedFlows: Long)

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
     * suppressed since the last emitted event) when an event should be emitted, or null when
     * the flow falls inside the current window and must not produce an event.
     */
    @Synchronized
    fun recordFlow(packageName: String): Long? {
        val now = elapsedMs()
        val window = windows[packageName]
        if (window != null && now - window.emittedAtMs < windowMs) {
            window.suppressedFlows++
            return null
        }
        val count = (window?.suppressedFlows ?: 0L) + 1L
        windows[packageName] = Window(emittedAtMs = now, suppressedFlows = 0L)
        return count
    }
}
