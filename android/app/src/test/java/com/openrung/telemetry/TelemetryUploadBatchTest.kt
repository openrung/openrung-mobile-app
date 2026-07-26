package com.openrung.telemetry

import com.openrung.telemetry.ApplicationConnectionAggregator.Companion.MAX_REPORTED_FLOWS
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TelemetryUploadBatchTest {
    @Test
    fun `same-application chunks are deferred across broker-compatible batches`() {
        val queued = listOf(
            event("a-1", application = "app.a", count = 1),
            event("a-max", application = "app.a", count = MAX_REPORTED_FLOWS),
            event("a-5", application = "app.a", count = 5),
            event("b-max", application = "app.b", count = MAX_REPORTED_FLOWS),
            event("ordinary"),
        )

        val batches = mutableListOf<List<TelemetryEvent>>()
        var remaining = queued
        while (remaining.isNotEmpty()) {
            val batch = telemetryUploadBatch(remaining, limit = 200)
            assertTrue("selector made no progress", batch.isNotEmpty())
            batches += batch
            val selectedIds = batch.mapTo(hashSetOf()) { it.eventId }
            remaining = remaining.filterNot { it.eventId in selectedIds }
        }

        assertEquals(
            listOf(
                listOf("a-1", "b-max", "ordinary"),
                listOf("a-max"),
                listOf("a-5"),
            ),
            batches.map { batch -> batch.map { it.eventId } },
        )
        assertEquals(queued.map { it.eventId }.sorted(), batches.flatten().map { it.eventId }.sorted())
        batches.forEach { batch ->
            batch.filter { it.event == APPLICATION_CONNECTION_EVENT }
                .groupBy { it.applicationPackage }
                .forEach { (_, events) ->
                    assertTrue(events.sumOf { it.brokerApplicationConnectionCount() } <= MAX_REPORTED_FLOWS)
                }
        }
    }

    @Test
    fun `batch weighting matches broker compatibility behavior`() {
        val counts = listOf<Long?>(null, 0, -1, MAX_REPORTED_FLOWS + 1, 42, MAX_REPORTED_FLOWS)
        assertEquals(
            listOf(1L, 1L, 1L, 1L, 42L, MAX_REPORTED_FLOWS),
            counts.mapIndexed { index, count ->
                event("event-$index", application = "app.$index", count = count)
                    .brokerApplicationConnectionCount()
            },
        )
    }

    @Test
    fun `batch stops at first client session identity boundary`() {
        val queued = listOf(
            event("a-1", clientId = "client-a", sessionId = "session-a"),
            event("a-2", clientId = "client-a", sessionId = "session-a"),
            event("b-1", clientId = "client-b", sessionId = "session-b"),
            event("a-3", clientId = "client-a", sessionId = "session-a"),
        )

        val first = telemetryUploadBatch(queued, limit = 200)
        assertEquals(listOf("a-1", "a-2"), first.map { it.eventId })

        val afterFirst = queued.filterNot { event -> first.any { it.eventId == event.eventId } }
        val second = telemetryUploadBatch(afterFirst, limit = 200)
        assertEquals(listOf("b-1"), second.map { it.eventId })

        val afterSecond = afterFirst.filterNot { event -> second.any { it.eventId == event.eventId } }
        assertEquals(listOf("a-3"), telemetryUploadBatch(afterSecond, 200).map { it.eventId })
    }

    @Test
    fun `sanitizer strips only application connection attributes`() {
        val attributes = mapOf("client_ip" to "203.0.113.9", "city" to "Example City")
        val applicationEvent = event("app", application = "app.a", count = 1).copy(attributes = attributes)
        val ordinaryEvent = event("ordinary").copy(attributes = attributes)

        assertTrue(sanitizeTelemetryEvent(applicationEvent).attributes.isEmpty())
        assertEquals(attributes, sanitizeTelemetryEvent(ordinaryEvent).attributes)
    }

    private fun event(
        id: String,
        application: String? = null,
        count: Long? = null,
        clientId: String = "client-1",
        sessionId: String = "session-1",
    ): TelemetryEvent =
        TelemetryEvent(
            eventId = id,
            event = if (application == null) "ordinary" else APPLICATION_CONNECTION_EVENT,
            occurredAt = "2026-07-21T00:00:00Z",
            clientId = clientId,
            sessionId = sessionId,
            applicationPackage = application,
            measurements = count?.let { mapOf(APPLICATION_CONNECTION_COUNT_MEASUREMENT to it) }.orEmpty(),
        )
}
