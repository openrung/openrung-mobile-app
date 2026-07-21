package com.openrung.telemetry

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import com.openrung.BuildConfig
import com.openrung.net.ClientGeoInfo
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

internal const val APPLICATION_CONNECTION_EVENT = "application_connection"
internal const val APPLICATION_CONNECTION_COUNT_MEASUREMENT = "connection_count"

object TelemetryManager {
    private const val PREFS = "openrung_telemetry"
    private const val KEY_OUTBOX = "outbox"
    private const val MAX_QUEUED_EVENTS = 500
    private const val UPLOAD_BATCH_SIZE = 200
    private const val DNS_PORT = 53
    private const val APP_CONNECTION_WINDOW_MS = 15 * 60 * 1000L

    private val lock = Any()
    private val appConnections = ApplicationConnectionAggregator(
        windowMs = APP_CONNECTION_WINDOW_MS,
        elapsedMs = SystemClock::elapsedRealtime,
    )
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private var context: Context? = null
    private var activeSession: Session? = null
    private var sessionTraffic: TrafficCounters? = null

    data class Session(
        val id: String,
        val clientId: String,
        val brokerUrl: String,
        val startedElapsedMs: Long,
        val relayId: String? = null,
        val connectedElapsedMs: Long? = null,
        val geoAttributes: Map<String, String> = emptyMap(),
    )

    /** Cumulative tunneled-traffic counters for the active session, as last reported by the engine. */
    data class TrafficCounters(val bytesSent: Long, val bytesReceived: Long) {
        /** Broker contract (openrung docs/api.md): cumulative per session, zero values omitted. */
        fun measurements(): Map<String, Long> = buildMap {
            if (bytesSent > 0) put("bytes_sent", bytesSent)
            if (bytesReceived > 0) put("bytes_received", bytesReceived)
        }
    }

    fun initialize(context: Context) {
        synchronized(lock) {
            // Unconditional: the application context is process-constant in production, and
            // holding on to the first one seen keeps Robolectric tests (fresh Application per
            // test method) writing to a stale instance's SharedPreferences.
            this.context = context.applicationContext
        }
    }

    fun clientId(context: Context): String = ClientIdentity.getOrCreate(context.applicationContext)

    fun beginSession(context: Context, brokerUrl: String): Session {
        initialize(context)
        val nextClientId = clientId(context)
        return synchronized(lock) {
            // A session can be replaced without ever ending (relay switch: ACTION_CONNECT while
            // connected reaches here with the old session still active). Draining and replacing
            // under the same lock linearizes the transition with native flow callbacks.
            activeSession?.let { outgoing ->
                enqueueAllLocked(
                    context.applicationContext,
                    appConnections.drainPending().map { it.toEvent(outgoing) },
                )
            } ?: appConnections.reset()
            val nextSession = Session(
                id = UUID.randomUUID().toString(),
                clientId = nextClientId,
                brokerUrl = brokerUrl,
                startedElapsedMs = SystemClock.elapsedRealtime(),
            )
            activeSession = nextSession
            sessionTraffic = null
            nextSession
        }
    }

    private fun ApplicationConnectionAggregator.PendingFlows.toEvent(session: Session): TelemetryEvent =
        applicationConnectionEvent(
            session = session,
            packageName = packageName,
            uid = uid,
            flowCount = flows,
        )

    private fun applicationConnectionEvent(
        session: Session,
        packageName: String,
        uid: Int,
        flowCount: Long,
    ): TelemetryEvent =
        TelemetryEvent(
            eventId = UUID.randomUUID().toString(),
            event = APPLICATION_CONNECTION_EVENT,
            occurredAt = Instant.now().toString(),
            clientId = session.clientId,
            sessionId = session.id,
            relayId = session.relayId,
            applicationPackage = packageName,
            applicationUid = uid,
            measurements = mapOf(APPLICATION_CONNECTION_COUNT_MEASUREMENT to flowCount),
        )

    private fun enqueueApplicationConnectionCountsLocked(
        appContext: Context,
        session: Session,
        packageName: String,
        uid: Int,
        flowCounts: List<Long>,
    ) {
        enqueueAllLocked(
            appContext,
            flowCounts.map { flowCount ->
                applicationConnectionEvent(session, packageName, uid, flowCount)
            },
        )
    }

    fun activeSession(): Session? = synchronized(lock) { activeSession }

    /**
     * Records the tunnel's traffic counters for the active session. Reported values must be
     * cumulative since the engine started; the high-water mark is kept so a counter reset
     * (engine restart) never regresses what the session already reported.
     */
    fun updateTrafficCounters(bytesSent: Long, bytesReceived: Long) {
        synchronized(lock) {
            if (activeSession == null) return
            val current = sessionTraffic
            sessionTraffic = TrafficCounters(
                bytesSent = maxOf(bytesSent, current?.bytesSent ?: 0L),
                bytesReceived = maxOf(bytesReceived, current?.bytesReceived ?: 0L),
            )
        }
    }

    private fun trafficCounters(): TrafficCounters? = synchronized(lock) { sessionTraffic }

    fun markConnected(relayId: String) {
        synchronized(lock) {
            activeSession = activeSession?.copy(
                relayId = relayId,
                connectedElapsedMs = SystemClock.elapsedRealtime(),
            )
        }
    }

    fun setGeoInfo(geoInfo: ClientGeoInfo) {
        val appContext = context ?: return
        val geoAttributes = geoInfo.telemetryAttributes()
        synchronized(lock) {
            val session = activeSession ?: return
            activeSession = session.copy(geoAttributes = geoAttributes)
            writeOutbox(
                appContext,
                readOutbox(appContext).map { event ->
                    when {
                        event.event == APPLICATION_CONNECTION_EVENT ->
                            event.copy(attributes = emptyMap())
                        event.sessionId == session.id ->
                            event.copy(attributes = event.attributes + geoAttributes)
                        else -> event
                    }
                },
            )
        }
        record("client_geo_resolved")
    }

    fun record(
        event: String,
        relayId: String? = null,
        attributes: Map<String, String> = emptyMap(),
        measurements: Map<String, Long> = emptyMap(),
    ) {
        val appContext = context ?: return
        val session = activeSession() ?: return
        enqueue(
            appContext,
            TelemetryEvent(
                eventId = UUID.randomUUID().toString(),
                event = event,
                occurredAt = Instant.now().toString(),
                clientId = session.clientId,
                sessionId = session.id,
                relayId = relayId ?: session.relayId,
                attributes = deviceAttributes(appContext) + session.geoAttributes + attributes,
                measurements = measurements,
            ),
        )
    }

    /**
     * Records a tunneled flow for the broker's per-application usage rollup. The broker keeps
     * only an hourly per-application count of these events and discards everything else in the
     * payload, so the event carries just the application identity: destination address, port and
     * protocol are never put on the wire (the client's IP paired with every destination visited
     * is a privacy hazard, transmitted for nothing). DNS flows are skipped entirely, repeated
     * flows normally collapse into one event per application per [APP_CONNECTION_WINDOW_MS]
     * (larger totals split into broker-bounded chunks), and a flow whose UID maps to several
     * packages reports only the first external package — never one event each.
     */
    fun recordApplicationConnection(
        uid: Int,
        packages: List<String>,
        destinationPort: Int,
    ) {
        if (destinationPort == DNS_PORT) return
        val appContext = synchronized(lock) { context } ?: return
        // PackageManager-backed lists can be slow or externally implemented. Resolve attribution
        // before taking the session lock; the callback belongs to whichever session is active at
        // the later atomic record point.
        val packageName = packages.firstOrNull { it != appContext.packageName } ?: return
        synchronized(lock) {
            val currentContext = context ?: return
            val session = activeSession ?: return
            val flowCounts = appConnections.recordFlow(packageName, uid)
            if (flowCounts.isEmpty()) return
            enqueueApplicationConnectionCountsLocked(currentContext, session, packageName, uid, flowCounts)
        }
    }

    fun endSession(reason: String) {
        synchronized(lock) {
            val appContext = context ?: return
            val session = activeSession ?: return
            val now = SystemClock.elapsedRealtime()
            val measurements = mutableMapOf("session_duration_ms" to (now - session.startedElapsedMs))
            session.connectedElapsedMs?.let { measurements["connection_duration_ms"] = now - it }
            sessionTraffic?.let { measurements.putAll(it.measurements()) }
            val endingEvents = appConnections.drainPending().map { it.toEvent(session) } +
                TelemetryEvent(
                    eventId = UUID.randomUUID().toString(),
                    event = "connection_ended",
                    occurredAt = Instant.now().toString(),
                    clientId = session.clientId,
                    sessionId = session.id,
                    relayId = session.relayId,
                    attributes = deviceAttributes(appContext) + session.geoAttributes + ("reason" to reason),
                    measurements = measurements,
                )
            enqueueAllLocked(appContext, endingEvents)
            activeSession = null
            sessionTraffic = null
        }
    }

    // NOTE(prototype): recordSpeedTest(SpeedTestResult) is not ported — the speed test
    // (and its speed_test_completed/failed telemetry) lives in the TypeScript shell.

    suspend fun sendHeartbeat() {
        val appContext = context ?: return
        val session = activeSession() ?: return
        val event = buildSessionHeartbeat(
            session = session,
            occurredAt = Instant.now(),
            elapsedRealtimeMs = SystemClock.elapsedRealtime(),
            attributes = deviceAttributes(appContext) + session.geoAttributes,
            trafficCounters = trafficCounters(),
        ) ?: return
        val queued = synchronized(lock) {
            telemetryUploadBatch(readOutbox(appContext), UPLOAD_BATCH_SIZE - 1)
        }
        TelemetryClient(session.brokerUrl).send(queued + event)
        if (queued.isNotEmpty()) {
            synchronized(lock) {
                val sentIDs = queued.mapTo(hashSetOf()) { it.eventId }
                writeOutbox(appContext, readOutbox(appContext).filterNot { it.eventId in sentIDs })
            }
            flush(session.brokerUrl)
        }
    }

    suspend fun flush(brokerUrl: String) {
        val appContext = context ?: return
        while (true) {
            val batch = synchronized(lock) {
                telemetryUploadBatch(readOutbox(appContext), UPLOAD_BATCH_SIZE)
            }
            if (batch.isEmpty()) return
            TelemetryClient(brokerUrl).send(batch)
            synchronized(lock) {
                val sentIDs = batch.mapTo(hashSetOf()) { it.eventId }
                writeOutbox(appContext, readOutbox(appContext).filterNot { it.eventId in sentIDs })
            }
        }
    }

    private fun enqueue(context: Context, event: TelemetryEvent) {
        synchronized(lock) {
            enqueueAllLocked(context, listOf(event))
        }
    }

    private fun enqueueAllLocked(context: Context, events: List<TelemetryEvent>) {
        if (events.isEmpty()) return
        writeOutbox(
            context,
            (readOutbox(context) + events.map(::sanitizeTelemetryEvent)).takeLast(MAX_QUEUED_EVENTS),
        )
    }

    private fun readOutbox(context: Context): List<TelemetryEvent> {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_OUTBOX, null)
            ?: return emptyList()
        return runCatching { json.decodeFromString<List<TelemetryEvent>>(encoded) }
            .getOrDefault(emptyList())
            .map(::sanitizeTelemetryEvent)
    }

    private fun writeOutbox(context: Context, events: List<TelemetryEvent>) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_OUTBOX, json.encodeToString(events))
            .apply()
    }

    private fun deviceAttributes(context: Context): Map<String, String> {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        return mapOf(
            "app_version" to BuildConfig.VERSION_NAME,
            "os_name" to "android",
            "android_api" to Build.VERSION.SDK_INT.toString(),
            "device_manufacturer" to Build.MANUFACTURER,
            "device_model" to Build.MODEL,
            "locale" to Locale.getDefault().toLanguageTag(),
            "timezone" to TimeZone.getDefault().id,
            "network_transport" to transportName(capabilities),
            "network_metered" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true).toString(),
            "network_roaming" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING) != true).toString(),
        )
    }

    private fun transportName(capabilities: NetworkCapabilities?): String = when {
        capabilities == null -> "unknown"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "other"
    }
}

/**
 * Removes client metadata that the broker never retains from application-connection records.
 * Applying this on every outbox read also scrubs events queued by an older app version before
 * either upload path can put them on the wire.
 */
internal fun sanitizeTelemetryEvent(event: TelemetryEvent): TelemetryEvent =
    if (event.event == APPLICATION_CONNECTION_EVENT && event.attributes.isNotEmpty()) {
        event.copy(attributes = emptyMap())
    } else {
        event
    }

/**
 * Selects one upload request while honoring the broker's 100,000 represented-flow budget per
 * application. Events that would exceed an application's remaining budget are deferred along
 * with later events for that application, preserving its FIFO order; unrelated events can still
 * fill the request. The caller removes selected event IDs after a successful send.
 */
internal fun telemetryUploadBatch(events: List<TelemetryEvent>, limit: Int): List<TelemetryEvent> {
    require(limit > 0) { "telemetry upload batch limit must be positive" }
    val representedByApplication = mutableMapOf<String, Long>()
    val deferredApplications = mutableSetOf<String>()
    return buildList {
        for (event in events) {
            if (size >= limit) break
            if (event.event != APPLICATION_CONNECTION_EVENT) {
                add(event)
                continue
            }

            val application = event.applicationPackage.orEmpty()
            if (application in deferredApplications) continue
            val count = event.brokerApplicationConnectionCount()
            val used = representedByApplication[application] ?: 0L
            if (count > ApplicationConnectionAggregator.MAX_REPORTED_FLOWS - used) {
                deferredApplications += application
                continue
            }
            representedByApplication[application] = used + count
            add(event)
        }
    }
}

/** Mirrors the broker's compatibility behavior for missing or malformed typed counts. */
internal fun TelemetryEvent.brokerApplicationConnectionCount(): Long {
    val count = measurements[APPLICATION_CONNECTION_COUNT_MEASUREMENT] ?: return 1L
    return if (count in 1..ApplicationConnectionAggregator.MAX_REPORTED_FLOWS) count else 1L
}

internal fun buildSessionHeartbeat(
    session: TelemetryManager.Session,
    occurredAt: Instant,
    elapsedRealtimeMs: Long,
    attributes: Map<String, String>,
    trafficCounters: TelemetryManager.TrafficCounters? = null,
): TelemetryEvent? {
    val relayId = session.relayId ?: return null
    val connectedElapsedMs = session.connectedElapsedMs ?: return null
    return TelemetryEvent(
        eventId = UUID.randomUUID().toString(),
        event = "session_heartbeat",
        occurredAt = occurredAt.toString(),
        clientId = session.clientId,
        sessionId = session.id,
        relayId = relayId,
        attributes = attributes + ("connection_state" to "connected"),
        measurements = mapOf(
            "session_duration_ms" to (elapsedRealtimeMs - session.startedElapsedMs).coerceAtLeast(0),
            "connected_duration_ms" to (elapsedRealtimeMs - connectedElapsedMs).coerceAtLeast(0),
        ) + (trafficCounters?.measurements() ?: emptyMap()),
    )
}
