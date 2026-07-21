package com.openrung.telemetry

import android.app.Application
import android.content.Context
import com.openrung.net.ClientGeoInfo
import java.time.Duration
import java.util.AbstractList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
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
 * enqueued event carries the application identity but no destination data, the 15-minute
 * production window is what actually gates re-emission, and session end flushes each window's
 * still-suppressed tail (the broker sums `connection_count`, so dropped tails would undercount).
 *
 * `TelemetryManager` is a process-wide singleton; each test's `beginSession` resets the
 * aggregator windows, so tests are isolated without any cross-test bookkeeping.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class TelemetryManagerApplicationConnectionTest {
    private lateinit var context: Context
    private lateinit var session: TelemetryManager.Session
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        clearOutbox()
        session = TelemetryManager.beginSession(context, "https://broker.invalid/")
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
        assertTrue(event.attributes.isEmpty())

        val stored = storedOutboxJson()
        assertFalse(stored.contains("destination_ip"))
        assertFalse(stored.contains("destination_port"))
        assertFalse(stored.contains("\"protocol\""))
    }

    @Test
    fun `repeated flows collapse into one event and the tail flushes at session end`() {
        repeat(25) { recordFlow(packageName = "com.example.repeated") }
        assertEquals(1, applicationConnectionEvents().size)

        // The 24 still-suppressed flows drain as one final event, so the broker's summed
        // per-app total (1 + 24) matches the flows that actually happened.
        TelemetryManager.endSession("test_flush")
        val events = applicationConnectionEvents()
        assertEquals(2, events.size)
        assertEquals(24L, events.last().measurements["connection_count"])
        assertEquals(25L, events.sumOf { it.measurements["connection_count"] ?: 0L })
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
    fun `session end flushes the tail under the ending session and the next session starts fresh`() {
        recordFlow(packageName = "com.example.newsession")
        recordFlow(packageName = "com.example.newsession")
        TelemetryManager.endSession("test_reconnect")
        val second = TelemetryManager.beginSession(context, "https://broker.invalid/")
        recordFlow(packageName = "com.example.newsession")

        val events = applicationConnectionEvents()
        assertEquals(3, events.size)
        assertEquals(listOf(1L, 1L, 1L), events.map { it.measurements["connection_count"] })
        // The drained tail is stamped with the session its flows happened under, and keeps
        // the application identity.
        assertEquals(listOf(session.id, session.id, second.id), events.map { it.sessionId })
        assertEquals("com.example.newsession", events[1].applicationPackage)
        assertEquals(10_001, events[1].applicationUid)
    }

    @Test
    fun `replacing a session without ending it flushes the tail under the old session`() {
        // The relay-switch path (ACTION_CONNECT while connected) calls beginSession with the
        // old session still active — no endSession in between.
        recordFlow(packageName = "com.example.switch")
        recordFlow(packageName = "com.example.switch")
        val second = TelemetryManager.beginSession(context, "https://broker.invalid/")
        recordFlow(packageName = "com.example.switch")

        val events = applicationConnectionEvents()
        assertEquals(3, events.size)
        assertEquals(listOf(session.id, session.id, second.id), events.map { it.sessionId })
        assertEquals(listOf(1L, 1L, 1L), events.map { it.measurements["connection_count"] })
    }

    @Test
    fun `flow attribution linearizes after package lookup during session replacement`() {
        recordFlow(packageName = "com.example.replace-race")
        val lookupEntered = CountDownLatch(1)
        val releaseLookup = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val callback = executor.submit {
                TelemetryManager.recordApplicationConnection(
                    uid = 10_001,
                    packages = BlockingPackageList("com.example.replace-race", lookupEntered, releaseLookup),
                    destinationPort = 443,
                )
            }
            assertTrue("flow callback did not enter package lookup", lookupEntered.await(5, TimeUnit.SECONDS))

            val second = TelemetryManager.beginSession(context, "https://broker.invalid/")
            releaseLookup.countDown()
            callback.get(5, TimeUnit.SECONDS)

            val events = applicationConnectionEvents()
                .filter { it.applicationPackage == "com.example.replace-race" }
            assertEquals(listOf(session.id, second.id), events.map { it.sessionId })
            assertEquals(listOf(1L, 1L), events.map { it.measurements["connection_count"] })
        } finally {
            releaseLookup.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `flow callback completing after session end emits nothing`() {
        recordFlow(packageName = "com.example.end-race")
        val lookupEntered = CountDownLatch(1)
        val releaseLookup = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val callback = executor.submit {
                TelemetryManager.recordApplicationConnection(
                    uid = 10_001,
                    packages = BlockingPackageList("com.example.end-race", lookupEntered, releaseLookup),
                    destinationPort = 443,
                )
            }
            assertTrue("flow callback did not enter package lookup", lookupEntered.await(5, TimeUnit.SECONDS))

            TelemetryManager.endSession("test_concurrent_end")
            releaseLookup.countDown()
            callback.get(5, TimeUnit.SECONDS)

            val events = applicationConnectionEvents()
                .filter { it.applicationPackage == "com.example.end-race" }
            assertEquals(1, events.size)
            assertEquals(session.id, events.single().sessionId)
        } finally {
            releaseLookup.countDown()
            executor.shutdownNow()
        }
    }

    @Test
    fun `application events omit geo metadata before after and during geo resolution`() {
        recordFlow(packageName = "com.example.before-geo")
        recordFlow(packageName = "com.example.before-geo")

        TelemetryManager.setGeoInfo(
            ClientGeoInfo(
                ip = "203.0.113.9",
                country = "Exampleland",
                countryCode = "EX",
                city = "Example City",
                asn = "AS64500",
                isp = "Example ISP",
                organization = "Example Org",
            ),
        )
        recordFlow(packageName = "com.example.after-geo")
        TelemetryManager.endSession("test_geo_privacy")

        val events = json.decodeFromString<List<TelemetryEvent>>(storedOutboxJson())
        val applicationEvents = events.filter { it.event == APPLICATION_CONNECTION_EVENT }
        assertEquals(3, applicationEvents.size)
        assertTrue(applicationEvents.all { it.attributes.isEmpty() })
        val geoEvent = events.single { it.event == "client_geo_resolved" }
        assertEquals("203.0.113.9", geoEvent.attributes["client_ip"])
        assertEquals("Example City", geoEvent.attributes["city"])
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
                    """"destination_ip":"93.184.216.34","destination_port":443,"protocol":"tcp",""" +
                    """"attributes":{"client_ip":"203.0.113.9","city":"Example City"}}]""",
            )
            .commit()

        recordFlow(packageName = "com.example.migrate")

        val stored = storedOutboxJson()
        assertTrue(stored.contains("legacy-1"))
        assertFalse(stored.contains("destination_ip"))
        assertFalse(stored.contains("93.184.216.34"))
        assertFalse(stored.contains("203.0.113.9"))
        assertFalse(stored.contains("Example City"))
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

    private class BlockingPackageList(
        private val packageName: String,
        private val entered: CountDownLatch,
        private val release: CountDownLatch,
    ) : AbstractList<String>() {
        override val size: Int = 1

        override fun get(index: Int): String {
            check(index == 0)
            entered.countDown()
            check(release.await(5, TimeUnit.SECONDS)) { "timed out waiting to release package lookup" }
            return packageName
        }
    }
}
