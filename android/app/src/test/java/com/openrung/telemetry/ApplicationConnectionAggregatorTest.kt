package com.openrung.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ApplicationConnectionAggregatorTest {
    private var nowMs = 0L
    private val aggregator = ApplicationConnectionAggregator(windowMs = WINDOW_MS) { nowMs }

    @Test
    fun `first flow for an application emits with count one`() {
        assertEquals(1L, aggregator.recordFlow("app.a"))
    }

    @Test
    fun `flows inside the window are suppressed`() {
        aggregator.recordFlow("app.a")
        assertNull(aggregator.recordFlow("app.a"))
        nowMs += WINDOW_MS - 1
        assertNull(aggregator.recordFlow("app.a"))
    }

    @Test
    fun `first flow after the window emits the collapsed count and resets it`() {
        aggregator.recordFlow("app.a")
        repeat(41) { assertNull(aggregator.recordFlow("app.a")) }
        nowMs += WINDOW_MS
        assertEquals(42L, aggregator.recordFlow("app.a"))
        nowMs += WINDOW_MS
        assertEquals(1L, aggregator.recordFlow("app.a"))
    }

    @Test
    fun `an idle window emits count one on the next flow`() {
        aggregator.recordFlow("app.a")
        nowMs += WINDOW_MS * 3
        assertEquals(1L, aggregator.recordFlow("app.a"))
    }

    @Test
    fun `applications are windowed independently`() {
        assertEquals(1L, aggregator.recordFlow("app.a"))
        assertEquals(1L, aggregator.recordFlow("app.b"))
        assertNull(aggregator.recordFlow("app.a"))
        assertNull(aggregator.recordFlow("app.b"))
    }

    private companion object {
        const val WINDOW_MS = 900_000L
    }
}
