package com.openrung.telemetry

import com.openrung.telemetry.ApplicationConnectionAggregator.Companion.MAX_REPORTED_FLOWS
import com.openrung.telemetry.ApplicationConnectionAggregator.PendingFlows
import org.junit.Assert.assertEquals
import org.junit.Test

class ApplicationConnectionAggregatorTest {
    private var nowMs = 0L
    private val aggregator = ApplicationConnectionAggregator(windowMs = WINDOW_MS) { nowMs }

    @Test
    fun `first flow for an application emits with count one`() {
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
    }

    @Test
    fun `flows inside the window are suppressed`() {
        aggregator.recordFlow("app.a", UID)
        assertEquals(emptyList<Long>(), aggregator.recordFlow("app.a", UID))
        nowMs += WINDOW_MS - 1
        assertEquals(emptyList<Long>(), aggregator.recordFlow("app.a", UID))
    }

    @Test
    fun `first flow after the window emits the collapsed count and resets it`() {
        aggregator.recordFlow("app.a", UID)
        repeat(41) { assertEquals(emptyList<Long>(), aggregator.recordFlow("app.a", UID)) }
        nowMs += WINDOW_MS
        assertEquals(listOf(42L), aggregator.recordFlow("app.a", UID))
        nowMs += WINDOW_MS
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
    }

    @Test
    fun `an idle window emits count one on the next flow`() {
        aggregator.recordFlow("app.a", UID)
        nowMs += WINDOW_MS * 3
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
    }

    @Test
    fun `applications are windowed independently`() {
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
        assertEquals(listOf(1L), aggregator.recordFlow("app.b", UID))
        assertEquals(emptyList<Long>(), aggregator.recordFlow("app.a", UID))
        assertEquals(emptyList<Long>(), aggregator.recordFlow("app.b", UID))
    }

    @Test
    fun `drainPending returns suppressed counts with the last seen uid and clears state`() {
        aggregator.recordFlow("app.a", UID)
        repeat(3) { aggregator.recordFlow("app.a", UID + 1) }
        aggregator.recordFlow("app.b", UID)

        assertEquals(
            listOf(PendingFlows(packageName = "app.a", uid = UID + 1, flows = 3L)),
            aggregator.drainPending(),
        )
        // Drained state is gone: the same app emits again immediately, from one.
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
        assertEquals(emptyList<PendingFlows>(), aggregator.drainPending())
    }

    @Test
    fun `elapsed window splits totals above the broker maximum without losing flows`() {
        aggregator.recordFlow("app.a", UID)
        repeat((MAX_REPORTED_FLOWS + 5).toInt()) { aggregator.recordFlow("app.a", UID) }
        nowMs += WINDOW_MS
        val emitted = aggregator.recordFlow("app.a", UID)

        assertEquals(listOf(MAX_REPORTED_FLOWS, 6L), emitted)
        assertEquals(MAX_REPORTED_FLOWS + 7L, 1L + emitted.sum())
    }

    @Test
    fun `drain splits pending totals above the broker maximum without losing flows`() {
        aggregator.recordFlow("app.a", UID)
        repeat((MAX_REPORTED_FLOWS + 5).toInt()) { aggregator.recordFlow("app.a", UID) }

        assertEquals(
            listOf(
                PendingFlows(packageName = "app.a", uid = UID, flows = MAX_REPORTED_FLOWS),
                PendingFlows(packageName = "app.a", uid = UID, flows = 5L),
            ),
            aggregator.drainPending(),
        )
        assertEquals(emptyList<PendingFlows>(), aggregator.drainPending())
    }

    @Test
    fun `reset drops pending counts`() {
        aggregator.recordFlow("app.a", UID)
        repeat(5) { aggregator.recordFlow("app.a", UID) }
        aggregator.reset()
        assertEquals(emptyList<PendingFlows>(), aggregator.drainPending())
        assertEquals(listOf(1L), aggregator.recordFlow("app.a", UID))
    }

    private companion object {
        const val WINDOW_MS = 900_000L
        const val UID = 10_001
    }
}
