package com.openrung.telemetry

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import com.openrung.BuildConfig
import com.openrung.net.ClientGeoInfo
import com.openrung.net.requireNativeBrokerSuccess
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.coroutines.coroutineContext

internal const val APPLICATION_CONNECTION_EVENT = "application_connection"
internal const val APPLICATION_CONNECTION_COUNT_MEASUREMENT = "connection_count"

/**
 * Session lifecycle and attribute assembly for native VPN telemetry. The outbox — persistence,
 * caps, upload batching, heartbeat piggybacking, and brokerapi posting — is the shared Go
 * implementation behind [TelemetryOutboxHandle] (`android/punchbridge/telemetry_binding.go`, the
 * same queue policy every OpenRung client runs); this file only decides WHAT to record and hands
 * fully-formed events over.
 */
object TelemetryManager {
    private const val PREFS = "openrung_telemetry"
    private const val KEY_OUTBOX = "outbox"
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

    /** Seam for the JVM suites: production resolves the gomobile-backed outbox lazily. */
    internal var outboxFactory: (Context) -> TelemetryOutboxHandle = ::NativeTelemetryOutbox
    private var outbox: TelemetryOutboxHandle? = null

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
            // test method) writing to a stale instance's storage.
            val next = context.applicationContext
            if (this.context !== next) {
                // A different Application instance (Robolectric per-test) invalidates the outbox
                // handle — its file lives under the new instance's filesDir.
                outbox = null
                cachedNetworkAttributes = null
            }
            this.context = next
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
     * Routes the still-current session through the broker front that won verified discovery.
     * The expected ID prevents a cancelled connect epoch from overwriting its successor's route.
     */
    fun updateBrokerUrl(sessionId: String, brokerUrl: String): Boolean = synchronized(lock) {
        val session = activeSession
        if (session == null || session.id != sessionId) return@synchronized false
        activeSession = session.copy(brokerUrl = brokerUrl)
        true
    }

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

    /**
     * Cumulative session counters as last pushed by the engine (null before the first push).
     * The tunnel health monitor compares successive values to skip probing while traffic is
     * demonstrably flowing.
     */
    fun currentTrafficCounters(): TrafficCounters? = trafficCounters()

    fun markConnected(relayId: String) {
        synchronized(lock) {
            activeSession = activeSession?.copy(
                relayId = relayId,
                connectedElapsedMs = SystemClock.elapsedRealtime(),
            )
        }
    }

    fun setGeoInfo(geoInfo: ClientGeoInfo) {
        val geoAttributes = geoInfo.telemetryAttributes()
        synchronized(lock) {
            val appContext = context ?: return
            val session = activeSession ?: return
            activeSession = session.copy(geoAttributes = geoAttributes)
            if (geoAttributes.isNotEmpty()) {
                // Back-patch the session's already-queued events so records from before the
                // public-IP lookup resolved still carry the geo attributes. The bound outbox
                // never patches application_connection rows, whose attributes stay empty.
                outboxLocked(appContext).applySessionAttributes(
                    session.id,
                    json.encodeToString(geoAttributes),
                )
            }
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
        val queued = TelemetryEvent(
            eventId = UUID.randomUUID().toString(),
            event = event,
            occurredAt = Instant.now().toString(),
            clientId = session.clientId,
            sessionId = session.id,
            relayId = relayId ?: session.relayId,
            attributes = deviceAttributes(appContext) + session.geoAttributes + attributes,
            measurements = measurements,
        )
        synchronized(lock) {
            enqueueAllLocked(appContext, listOf(queued))
        }
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
        val heartbeat = buildSessionHeartbeat(
            session = session,
            occurredAt = Instant.now(),
            elapsedRealtimeMs = SystemClock.elapsedRealtime(),
            attributes = deviceAttributes(appContext) + session.geoAttributes,
            trafficCounters = trafficCounters(),
        ) ?: return
        val handle = synchronized(lock) { outboxLocked(appContext) }
        val heartbeatJson = json.encodeToString(heartbeat)
        val result = withContext(Dispatchers.IO) {
            handle.sendHeartbeat(session.brokerUrl, heartbeatJson)
        }
        requireNativeBrokerSuccess(result, "native telemetry heartbeat")
        if (result.pendingCount > 0) flush(session.brokerUrl)
    }

    suspend fun flush(brokerUrl: String) {
        val appContext = context ?: return
        val handle = synchronized(lock) { outboxLocked(appContext) }
        while (true) {
            val result = withContext(Dispatchers.IO) { handle.flushNextBatch(brokerUrl) }
            requireNativeBrokerSuccess(result, "native telemetry upload")
            if (result.pendingCount == 0) return
            coroutineContext.ensureActive()
        }
    }

    private fun enqueueAllLocked(context: Context, events: List<TelemetryEvent>) {
        if (events.isEmpty()) return
        val handle = outboxLocked(context)
        events.forEach { event -> handle.enqueue(json.encodeToString(event)) }
    }

    /**
     * Resolves the bound outbox, importing the pre-file SharedPreferences backlog exactly once:
     * the blob is read WITHOUT clearing, handed to the bound outbox (which persists it durably
     * before returning), and only then removed — a crash mid-import can never discard the
     * pre-upgrade backlog, and a key left behind by an interrupted removal is re-imported as
     * duplicates the broker deduplicates by event id.
     */
    private fun outboxLocked(context: Context): TelemetryOutboxHandle {
        outbox?.let { return it }
        val handle = outboxFactory(context)
        outbox = handle
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        prefs.getString(KEY_OUTBOX, null)?.let { encoded ->
            handle.enqueueBatch(encoded)
            prefs.edit().remove(KEY_OUTBOX).apply()
        }
        return handle
    }

    /** Truly process-constant attributes, built once. */
    private val staticDeviceAttributes: Map<String, String> by lazy {
        mapOf(
            "app_version" to BuildConfig.VERSION_NAME,
            "os_name" to "android",
            "android_api" to Build.VERSION.SDK_INT.toString(),
            "device_manufacturer" to Build.MANUFACTURER,
            "device_model" to Build.MODEL,
        )
    }

    /**
     * Short-lived cache for the network attributes: resolving them costs two binder calls, and
     * events cluster in bursts (connect ladder, recovery), so a small TTL removes almost all of
     * that IPC without reporting stale transports.
     */
    private const val NETWORK_ATTRIBUTES_TTL_MS = 5_000L
    private var cachedNetworkAttributes: Pair<Long, Map<String, String>>? = null

    private fun deviceAttributes(context: Context): Map<String, String> {
        val now = SystemClock.elapsedRealtime()
        val cached = synchronized(lock) { cachedNetworkAttributes }
        val network = if (cached != null && now - cached.first < NETWORK_ATTRIBUTES_TTL_MS) {
            cached.second
        } else {
            val connectivity = context.getSystemService(ConnectivityManager::class.java)
            val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
            val fresh = mapOf(
                "network_transport" to transportName(capabilities),
                "network_metered" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED) != true).toString(),
                "network_roaming" to (capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING) != true).toString(),
            )
            synchronized(lock) { cachedNetworkAttributes = now to fresh }
            fresh
        }
        // Locale/timezone can change mid-process and are cheap to read — keep them live.
        return staticDeviceAttributes +
            mapOf(
                "locale" to Locale.getDefault().toLanguageTag(),
                "timezone" to TimeZone.getDefault().id,
            ) + network
    }

    private fun transportName(capabilities: NetworkCapabilities?): String = when {
        capabilities == null -> "unknown"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
        else -> "other"
    }
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
