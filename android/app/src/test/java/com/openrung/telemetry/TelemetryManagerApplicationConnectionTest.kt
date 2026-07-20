package com.openrung.telemetry

import android.app.Application
import android.content.Context
import java.time.Duration
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowSystemClock

/**
 * Covers the `application_connection` emission policy end to end: DNS flows and the app's own
 * traffic emit nothing, a multi-package UID emits a single event (no per-package fan-out), the
 * enqueued event carries the application identity but no destination data, and the 15-minute
 * production window is what actually gates re-emission.
 *
 * `TelemetryManager` is a process-wide singleton; each test's `beginSession` resets the
 * aggregator windows, so tests are isolated without any cross-test bookkeeping.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class TelemetryManagerApplicationConnectionTest {
    private lateinit var context: Context
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        clearOutbox()
        TelemetryManager.beginSession(context, "https://broker.invalid/")
    }

    @After
    fun tearDown() {
        TelemetryManager.endSession("test_teardown")
        clearOutbox()
    }

    @Test
    fun `dns flows emit nothing and do not open an aggregation window`() {
        recordFlow(packageName = "com.example.dnsflow", destinationPort = 53)
        assertEquals(emptyList<TelemetryEvent>(), applicationConnectionEvents())

        // A DNS flow must not occupy the window or count: the next real flow still emits, as 1.
        recordFlow(packageName = "com.example.dnsflow", destinationPort = 443)
        val events = applicationConnectionEvents()
        assertEquals(1, events.size)
        assertEquals(1L, events.single().measurements["connection_count"])
    }

    @Test
    fun `a flow emits one event with the app identity and no destination data`() {
        TelemetryManager.recordApplicationConnection(
            uid = 10_002,
            packages = listOf("com.example.identity", "com.example.identity.sharee"),
            destinationPort = 443,
        )

        val events = applicationConnectionEvents()
        assertEquals(1, events.size)
        val event = events.single()
        assertEquals("application_connection", event.event)
        assertEquals("com.example.identity", event.applicationPackage)
        assertEquals(10_002, event.applicationUid)
        assertEquals(1L, event.measurements["connection_count"])

        val stored = storedOutboxJson()
        assertFalse(stored.contains("destination_ip"))
        assertFalse(stored.contains("destination_port"))
        assertFalse(stored.contains("\"protocol\""))
    }

    @Test
    fun `repeated flows inside the window collapse into one event`() {
        repeat(25) { recordFlow(packageName = "com.example.repeated") }
        assertEquals(1, applicationConnectionEvents().size)
    }

    @Test
    fun `the fifteen-minute window gates re-emission and reports the collapsed count`() {
        repeat(3) { recordFlow(packageName = "com.example.window") }
        ShadowSystemClock.advanceBy(Duration.ofMinutes(15).minusMillis(1))
        recordFlow(packageName = "com.example.window")
        assertEquals(1, applicationConnectionEvents().size)

        ShadowSystemClock.advanceBy(Duration.ofMillis(1))
        recordFlow(packageName = "com.example.window")
        val events = applicationConnectionEvents()
        assertEquals(2, events.size)
        assertEquals(4L, events.last().measurements["connection_count"])
    }

    @Test
    fun `a new session resets the aggregation windows`() {
        recordFlow(packageName = "com.example.newsession")
        recordFlow(packageName = "com.example.newsession")
        TelemetryManager.endSession("test_reconnect")
        TelemetryManager.beginSession(context, "https://broker.invalid/")

        recordFlow(packageName = "com.example.newsession")
        val events = applicationConnectionEvents()
        assertEquals(2, events.size)
        // The suppressed flow from the previous session is not carried into this session's count.
        assertEquals(1L, events.last().measurements["connection_count"])
    }

    @Test
    fun `the app's own traffic emits nothing`() {
        recordFlow(packageName = context.packageName)
        assertEquals(emptyList<TelemetryEvent>(), applicationConnectionEvents())
    }

    @Test
    fun `no active session emits nothing`() {
        TelemetryManager.endSession("test_no_session")
        recordFlow(packageName = "com.example.nosession")
        assertTrue(applicationConnectionEvents().isEmpty())
    }

    @Test
    fun `a pre-upgrade outbox backlog is scrubbed of destination data on the next write`() {
        context.getSharedPreferences("openrung_telemetry", Context.MODE_PRIVATE)
            .edit()
            .putString(
                "outbox",
                """[{"schema_version":1,"event_id":"legacy-1","event":"application_connection",""" +
                    """"occurred_at":"2026-07-01T00:00:00Z","client_id":"c","session_id":"s",""" +
                    """"application_package":"com.example.legacy","application_uid":10099,""" +
                    """"destination_ip":"93.184.216.34","destination_port":443,"protocol":"tcp"}]""",
            )
            .commit()

        recordFlow(packageName = "com.example.migrate")

        val stored = storedOutboxJson()
        assertTrue(stored.contains("legacy-1"))
        assertFalse(stored.contains("destination_ip"))
        assertFalse(stored.contains("93.184.216.34"))
    }

    private fun recordFlow(packageName: String, destinationPort: Int = 443) {
        TelemetryManager.recordApplicationConnection(
            uid = 10_001,
            packages = listOf(packageName),
            destinationPort = destinationPort,
        )
    }

    private fun applicationConnectionEvents(): List<TelemetryEvent> =
        json.decodeFromString<List<TelemetryEvent>>(storedOutboxJson())
            .filter { it.event == "application_connection" }

    private fun storedOutboxJson(): String =
        context.getSharedPreferences("openrung_telemetry", Context.MODE_PRIVATE)
            .getString("outbox", null) ?: "[]"

    private fun clearOutbox() {
        context.getSharedPreferences("openrung_telemetry", Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }
}
