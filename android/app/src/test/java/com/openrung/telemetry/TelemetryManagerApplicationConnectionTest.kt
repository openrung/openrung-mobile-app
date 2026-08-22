package com.openrung.telemetry

import android.app.Application
import android.content.Context
import com.openrung.net.ClientGeoInfo
import java.time.Duration
import java.util.AbstractList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
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
 * aggregator windows, so tests are isolated without any cross-test bookkeeping. The bound native
 * outbox is replaced with a recording fake — a JVM test cannot load the gomobile engine — so
 * these tests pin WHAT the manager hands the outbox; the queue/upload policy itself is pinned by
 * `android/punchbridge`'s Go suite against the real binding.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class TelemetryManagerApplicationConnectionTest {
    private lateinit var context: Context
    private lateinit var session: TelemetryManager.Session
    private lateinit var outbox: FakeTelemetryOutbox
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }

    @Before
    fun setUp() {
        context = RuntimeEnvironment.getApplication()
        clearLegacyPreferences()
        outbox = FakeTelemetryOutbox(json)
        TelemetryManager.outboxFactory = { outbox }
        session = TelemetryManager.beginSession(context, "https://broker.invalid/")
    }

    @After
    fun tearDown() {
        TelemetryManager.endSession("test_teardown")
        TelemetryManager.outboxFactory = ::NativeTelemetryOutbox
        clearLegacyPreferences()
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
    fun `verified discovery winner reroutes only its matching active session`() {
        assertTrue(TelemetryManager.updateBrokerUrl(session.id, "https://winner.example/"))
        assertEquals("https://winner.example/", TelemetryManager.activeSession()?.brokerUrl)

        val successor = TelemetryManager.beginSession(context, "https://successor.example/")
        assertFalse(TelemetryManager.updateBrokerUrl(session.id, "https://stale.example/"))
        assertEquals(successor, TelemetryManager.activeSession())
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

        val events = outbox.events.toList()
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
    fun `a pre-file preference backlog is imported into the bound outbox exactly once`() {
        // The pre-NDJSON SharedPreferences blob. The bound outbox owns the scrubbing of its
        // removed destination fields (pinned in android/punchbridge's Go suite); this side's
        // contract is the safe hand-over: read without clearing, import, only then remove the
        // key — a crash mid-import can never discard the pre-upgrade backlog.
        val blob =
            """[{"schema_version":1,"event_id":"legacy-1","event":"application_connection",""" +
                """"occurred_at":"2026-07-01T00:00:00Z","client_id":"c","session_id":"s",""" +
                """"application_package":"com.example.legacy","application_uid":10099}]"""
        val prefs = context.getSharedPreferences("openrung_telemetry", Context.MODE_PRIVATE)
        prefs.edit().putString("outbox", blob).commit()
        // The one-time import runs when the outbox handle is first resolved, which the first
        // enqueue below triggers (nothing in setUp touches the outbox).
        recordFlow(packageName = "com.example.migrate")

        assertEquals(listOf(blob), outbox.batchImports)
        assertFalse("the key must be cleared once the import landed", prefs.contains("outbox"))
        // The import lands before the event that triggered the resolution.
        assertEquals("com.example.migrate", outbox.events.single().applicationPackage)
    }

    @Test
    fun `cancelling a flush closes the in-flight native upload`() = runBlocking {
        // The terminal-flush deadline (withTimeoutOrNull around flush) must never be held
        // hostage by an unresponsive broker: cancellation closes the single-use upload, which
        // unblocks the native call, and waits for it to return before propagating. The
        // close-before-start half of the gate lives in the bound upload's own mutex, pinned by
        // android/punchbridge's Go suite.
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val closed = CountDownLatch(1)
        val blocking = object : TelemetryOutboxHandle by outbox {
            override fun beginUpload(): TelemetryUploadHandle = object : TelemetryUploadHandle {
                override fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult {
                    entered.countDown()
                    check(release.await(5, TimeUnit.SECONDS)) { "upload was never closed" }
                    return NativeTelemetryFlushResult(succeeded = false, errorKind = "cancelled")
                }

                override fun sendHeartbeat(
                    brokerUrl: String,
                    heartbeatJson: String,
                ): NativeTelemetryFlushResult = throw AssertionError("flush must not send heartbeats")

                override fun close() {
                    closed.countDown()
                    release.countDown()
                }
            }
        }
        TelemetryManager.outboxFactory = { blocking }

        val flushJob = launch(Dispatchers.Default) {
            runCatching { TelemetryManager.flush("https://broker.invalid/") }
        }
        assertTrue("flush never reached the native call", entered.await(5, TimeUnit.SECONDS))
        flushJob.cancelAndJoin()
        assertTrue(
            "cancellation must close the in-flight upload",
            closed.await(1, TimeUnit.SECONDS),
        )
    }

    @Test
    fun `a failed preference import keeps the backlog for a later retry`() {
        // -1 is the bound outbox saying nothing durable landed (unwritable directory, closed or
        // unavailable binding). The only copy of the backlog must survive for the next open.
        val blob =
            """[{"schema_version":1,"event_id":"legacy-2","event":"connection_failed",""" +
                """"occurred_at":"2026-07-01T00:00:00Z","client_id":"c","session_id":"s"}]"""
        val prefs = context.getSharedPreferences("openrung_telemetry", Context.MODE_PRIVATE)
        prefs.edit().putString("outbox", blob).commit()
        outbox.batchImportResult = -1

        recordFlow(packageName = "com.example.migrate-failed")

        assertEquals(listOf(blob), outbox.batchImports)
        assertTrue("the key must survive a failed import", prefs.contains("outbox"))
    }

    private fun recordFlow(packageName: String, destinationPort: Int = 443) {
        TelemetryManager.recordApplicationConnection(
            uid = 10_001,
            packages = listOf(packageName),
            destinationPort = destinationPort,
        )
    }

    private fun applicationConnectionEvents(): List<TelemetryEvent> =
        outbox.events.filter { it.event == "application_connection" }

    /** The enqueued events re-encoded, keeping the existing contains-assertions meaningful. */
    private fun storedOutboxJson(): String = outbox.storedJson()

    private fun clearLegacyPreferences() {
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

/**
 * Recording stand-in for the bound native outbox. Decodes enqueued events so assertions read
 * naturally; flushes always succeed with an empty queue (upload policy is Go-tested).
 */
internal class FakeTelemetryOutbox(private val json: Json) : TelemetryOutboxHandle {
    val events = mutableListOf<TelemetryEvent>()
    val batchImports = mutableListOf<String>()
    val sessionAttributePatches = mutableListOf<Pair<String, String>>()

    override fun enqueue(eventJson: String): Boolean {
        events.add(json.decodeFromString<TelemetryEvent>(eventJson))
        return true
    }

    /** The durability answer the next import receives: 0 = complete, -1 = keep the source. */
    var batchImportResult: Int = 0

    override fun enqueueBatch(eventsJson: String): Int {
        batchImports.add(eventsJson)
        return batchImportResult
    }

    override fun applySessionAttributes(sessionId: String, attributesJson: String) {
        sessionAttributePatches.add(sessionId to attributesJson)
    }

    override fun beginUpload(): TelemetryUploadHandle = object : TelemetryUploadHandle {
        override fun flushNextBatch(brokerUrl: String): NativeTelemetryFlushResult =
            NativeTelemetryFlushResult(succeeded = true)

        override fun sendHeartbeat(brokerUrl: String, heartbeatJson: String): NativeTelemetryFlushResult =
            NativeTelemetryFlushResult(succeeded = true)

        override fun close() = Unit
    }

    fun storedJson(): String =
        events.joinToString(",", "[", "]") { json.encodeToString(it) }
}
