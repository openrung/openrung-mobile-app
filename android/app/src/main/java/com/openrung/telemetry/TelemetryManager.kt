package com.openrung.telemetry

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import com.openrung.BuildConfig
import com.openrung.net.ClientGeoInfo
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.time.Instant
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import kotlin.coroutines.coroutineContext

internal const val APPLICATION_CONNECTION_EVENT = "application_connection"
internal const val APPLICATION_CONNECTION_COUNT_MEASUREMENT = "connection_count"

object TelemetryManager {
    private const val PREFS = "openrung_telemetry"
    private const val KEY_OUTBOX = "outbox"
    private const val MAX_QUEUED_EVENTS = 500
    private const val UPLOAD_BATCH_SIZE = 200
    private const val DNS_PORT = 53
    private const val APP_CONNECTION_WINDOW_MS = 15 * 60 * 1000L
    private const val OUTBOX_FILE = "openrung_telemetry_outbox.jsonl"

    /**
     * The outbox file may carry more lines than the in-memory cap before it is compacted; past
     * this it is rewritten from the cache, so append cost stays O(1) amortized per event.
     */
    private const val OUTBOX_COMPACT_THRESHOLD = 2 * MAX_QUEUED_EVENTS

    private val lock = Any()

    /**
     * In-memory outbox mirror (guarded by [lock]) over an append-only NDJSON file. Appending one
     * event encodes and writes ONE line; the previous SharedPreferences blob decoded and
     * re-encoded the entire queue (up to [MAX_QUEUED_EVENTS] events, hundreds of KB) on every
     * append — O(n²) CPU/disk per session, worst exactly when a blocked network keeps the queue
     * full. The file is rewritten only when uploads remove events, geo attributes are
     * back-patched, or the tail outgrows [OUTBOX_COMPACT_THRESHOLD]; a torn final line from a
     * process kill is skipped at load.
     */
    private var outboxCache: MutableList<TelemetryEvent>? = null
    private var outboxFileLines = 0

    /**
     * True while a legacy SharedPreferences outbox has been read into the cache but not yet
     * durably written to the NDJSON file. Until the migration lands (an atomic-rename rewrite),
     * the legacy key stays in place and appends retry the full rewrite — appending alone would
     * create a file WITHOUT the backlog, and the file's existence is what marks the migration
     * complete on the next launch.
     */
    private var legacyMigrationPending = false
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
            val next = context.applicationContext
            if (this.context !== next) {
                // A different Application instance (Robolectric per-test) invalidates the outbox
                // cache — its file lives under the new instance's filesDir.
                outboxCache = null
                outboxFileLines = 0
                legacyMigrationPending = false
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
        val appContext = context ?: return
        val geoAttributes = geoInfo.telemetryAttributes()
        synchronized(lock) {
            val session = activeSession ?: return
            activeSession = session.copy(geoAttributes = geoAttributes)
            transformOutboxLocked(appContext) { event ->
                when {
                    event.event == APPLICATION_CONNECTION_EVENT ->
                        event.copy(attributes = emptyMap())
                    event.sessionId == session.id ->
                        event.copy(attributes = event.attributes + geoAttributes)
                    else -> event
                }
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
        sendHeartbeatWithQueuedEvents(
            heartbeat = event,
            batchSize = UPLOAD_BATCH_SIZE,
            readQueued = {
                synchronized(lock) { outboxSnapshotLocked(appContext) }
            },
            send = { TelemetryClient(session.brokerUrl).send(it) },
            commit = { sentIDs ->
                synchronized(lock) { removeFromOutboxLocked(appContext, sentIDs) }
            },
            flushQueued = { flush(session.brokerUrl) },
        )
    }

    suspend fun flush(brokerUrl: String) {
        val appContext = context ?: return
        while (true) {
            val batch = synchronized(lock) {
                telemetryUploadBatch(outboxSnapshotLocked(appContext), UPLOAD_BATCH_SIZE)
            }
            if (batch.isEmpty()) return
            sendTelemetryBatchAndCommit(
                events = batch,
                queuedEventIds = batch.mapTo(hashSetOf()) { it.eventId },
                send = { TelemetryClient(brokerUrl).send(it) },
                commit = { sentIDs ->
                    synchronized(lock) { removeFromOutboxLocked(appContext, sentIDs) }
                },
            )
        }
    }

    private fun enqueue(context: Context, event: TelemetryEvent) {
        synchronized(lock) {
            enqueueAllLocked(context, listOf(event))
        }
    }

    private fun enqueueAllLocked(context: Context, events: List<TelemetryEvent>) {
        if (events.isEmpty()) return
        val cache = loadOutboxLocked(context)
        val sanitized = events.map(::sanitizeTelemetryEvent)
        cache.addAll(sanitized)
        while (cache.size > MAX_QUEUED_EVENTS) cache.removeAt(0)
        if (legacyMigrationPending) {
            // See [legacyMigrationPending]: the backlog must land as one durable rewrite before
            // plain appends may touch the file.
            rewriteOutboxLocked(context, cache)
            return
        }
        val appended = runCatching {
            outboxFile(context).appendText(
                sanitized.joinToString(separator = "") { json.encodeToString(it) + "\n" },
            )
        }.isSuccess
        outboxFileLines += sanitized.size
        if (!appended || outboxFileLines > OUTBOX_COMPACT_THRESHOLD) {
            rewriteOutboxLocked(context, cache)
        }
    }

    /** Immutable snapshot for consumers that iterate outside [lock]. */
    private fun outboxSnapshotLocked(context: Context): List<TelemetryEvent> =
        loadOutboxLocked(context).toList()

    private fun removeFromOutboxLocked(context: Context, ids: Set<String>) {
        if (ids.isEmpty()) return
        val cache = loadOutboxLocked(context)
        if (cache.removeAll { it.eventId in ids }) {
            rewriteOutboxLocked(context, cache)
        }
    }

    private fun transformOutboxLocked(context: Context, transform: (TelemetryEvent) -> TelemetryEvent) {
        val cache = loadOutboxLocked(context)
        var changed = false
        for (index in cache.indices) {
            val next = transform(cache[index])
            if (next != cache[index]) {
                cache[index] = next
                changed = true
            }
        }
        if (changed) rewriteOutboxLocked(context, cache)
    }

    private fun outboxFile(context: Context): File = File(context.filesDir, OUTBOX_FILE)

    private fun loadOutboxLocked(context: Context): MutableList<TelemetryEvent> {
        outboxCache?.let { return it }
        val file = outboxFile(context)
        var needsRewrite: Boolean
        val parsed: List<TelemetryEvent>
        if (file.isFile) {
            // The file is authoritative once it exists (rewrites land via atomic rename). A
            // legacy key still present next to it is a completed migration whose key removal
            // didn't land — stale, so drop it without another read.
            clearLegacyOutboxLocked(context)
            val lines = runCatching {
                file.useLines { sequence -> sequence.filter { it.isNotBlank() }.toList() }
            }.getOrDefault(emptyList())
            val decoded = lines.mapNotNull { line ->
                runCatching { json.decodeFromString<TelemetryEvent>(line) }.getOrNull()
            }
            needsRewrite = decoded.size != lines.size
            parsed = decoded
        } else {
            val legacy = readLegacyOutboxLocked(context)
            legacyMigrationPending = legacy != null
            needsRewrite = legacy != null
            parsed = legacy.orEmpty()
        }
        val events = parsed.map(::sanitizeTelemetryEvent)
            .takeLast(MAX_QUEUED_EVENTS)
            .toMutableList()
        if (needsRewrite || events.size != parsed.size) {
            rewriteOutboxLocked(context, events)
        } else {
            outboxFileLines = events.size
        }
        outboxCache = events
        return events
    }

    /** Reads the pre-file SharedPreferences blob WITHOUT clearing it — the key is removed only
     *  once the migrated file has durably landed (see [rewriteOutboxLocked]), so disk-full, an
     *  I/O failure, or a crash mid-migration can never discard the pre-upgrade backlog. */
    private fun readLegacyOutboxLocked(context: Context): List<TelemetryEvent>? {
        val encoded = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_OUTBOX, null) ?: return null
        return runCatching { json.decodeFromString<List<TelemetryEvent>>(encoded) }
            .getOrDefault(emptyList())
    }

    private fun clearLegacyOutboxLocked(context: Context) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_OUTBOX)) prefs.edit().remove(KEY_OUTBOX).apply()
    }

    private fun rewriteOutboxLocked(context: Context, events: List<TelemetryEvent>): Boolean {
        val file = outboxFile(context)
        val wrote = runCatching {
            val temp = File(file.parentFile, "$OUTBOX_FILE.tmp")
            temp.writeText(events.joinToString(separator = "") { json.encodeToString(it) + "\n" })
            if (!temp.renameTo(file)) {
                file.writeText(events.joinToString(separator = "") { json.encodeToString(it) + "\n" })
                temp.delete()
            }
        }.isSuccess
        if (wrote) {
            outboxFileLines = events.size
            if (legacyMigrationPending) {
                legacyMigrationPending = false
                clearLegacyOutboxLocked(context)
            }
        }
        return wrote
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

/**
 * Commits queued IDs only after a send completed while the caller is still active. Keeping this
 * check adjacent to the outbox mutation closes the native-success/caller-cancellation race.
 */
internal suspend fun sendTelemetryBatchAndCommit(
    events: List<TelemetryEvent>,
    queuedEventIds: Set<String>,
    send: suspend (List<TelemetryEvent>) -> Unit,
    commit: (Set<String>) -> Unit,
) {
    send(events)
    coroutineContext.ensureActive()
    if (queuedEventIds.isNotEmpty()) commit(queuedEventIds)
}

/**
 * Sends a heartbeat without ever mixing identity pairs in one brokerapi batch.
 *
 * Only a head prefix matching [heartbeat] may piggyback. If the head belongs to an older session,
 * the heartbeat is sent alone first so historical backlog (or a failure uploading it) cannot
 * suppress heartbeat cadence. [flushQueued] then drains every remaining homogeneous prefix in
 * queue order. A failed or cancelled send commits nothing from that request.
 */
internal suspend fun sendHeartbeatWithQueuedEvents(
    heartbeat: TelemetryEvent,
    batchSize: Int,
    readQueued: () -> List<TelemetryEvent>,
    send: suspend (List<TelemetryEvent>) -> Unit,
    commit: (Set<String>) -> Unit,
    flushQueued: suspend () -> Unit,
) {
    require(batchSize > 1) { "heartbeat telemetry batch size must exceed one" }
    val pending = readQueued()
    val queued = if (pending.firstOrNull()?.hasSameTelemetryIdentity(heartbeat) == true) {
        telemetryUploadBatch(pending, batchSize - 1)
    } else {
        emptyList()
    }
    sendTelemetryBatchAndCommit(
        events = queued + heartbeat,
        queuedEventIds = queued.mapTo(hashSetOf()) { it.eventId },
        send = send,
        commit = commit,
    )
    flushQueued()
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
 * Selects one upload request from the first event's client/session identity prefix while honoring
 * the broker's 100,000 represented-flow budget per application. The identity boundary is strict:
 * brokerapi rejects mixed pairs, and later sessions cannot leapfrog the head session. Within that
 * prefix, events that exceed an application's remaining budget are deferred along with later
 * events for that application; unrelated events may still fill the request as before. The caller
 * removes selected event IDs only after a successful send.
 */
internal fun telemetryUploadBatch(events: List<TelemetryEvent>, limit: Int): List<TelemetryEvent> {
    require(limit > 0) { "telemetry upload batch limit must be positive" }
    val first = events.firstOrNull() ?: return emptyList()
    val identityPrefix = events.takeWhile { it.hasSameTelemetryIdentity(first) }
    val representedByApplication = mutableMapOf<String, Long>()
    val deferredApplications = mutableSetOf<String>()
    return buildList {
        for (event in identityPrefix) {
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

private fun TelemetryEvent.hasSameTelemetryIdentity(other: TelemetryEvent): Boolean =
    clientId == other.clientId && sessionId == other.sessionId

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
