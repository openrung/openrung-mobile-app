package com.openrung.telemetry

import org.junit.Assert.*
import org.junit.Test

/** Expectations retained from the shipping TelemetryManager/aggregator, main 53e03d9. */
class RunApplicationConnectionsTest {
    @Test fun `DNS and own package are excluded and tail counts drain once`() {
        val reports = mutableListOf<Triple<String,Int,Long>>()
        val run = RunApplicationConnections("self", { 0L }) { name, uid, count -> reports.add(Triple(name,uid,count)) }
        run.record(5, listOf("browser"), 53)
        run.record(5, listOf("self"), 443)
        repeat(4) { run.record(5, listOf("browser", "browser"), 443) }
        assertEquals(listOf(Triple("browser",5,1L)), reports)
        run.close(); run.close()
        assertEquals(listOf(Triple("browser",5,1L), Triple("browser",5,3L)), reports)
    }

    @Test fun `retired callbacks cannot enter a successor session`() {
        var oldCount = 0L; var newCount = 0L
        val old = RunApplicationConnections("self", { 0L }) { _, _, count -> oldCount += count }
        old.record(1,listOf("browser"),443); old.close()
        val next = RunApplicationConnections("self", { 0L }) { _, _, count -> newCount += count }
        old.record(1,listOf("browser"),443)
        next.record(1,listOf("browser"),443); next.close()
        assertEquals(1L, oldCount); assertEquals(1L, newCount)
    }
}
