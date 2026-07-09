package com.openrung.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import com.openrung.MainActivity
import com.openrung.R
import com.openrung.config.AppConfig
import com.openrung.model.CountryGeo
import com.openrung.model.RecentNode
import com.openrung.model.RelayDescriptor
import com.openrung.model.RelaySelector
import com.openrung.net.BrokerClient
import com.openrung.net.GeoIpClient
import com.openrung.net.InternetProbe
import com.openrung.net.RelayReachability
import com.openrung.net.SingBoxConfiguration
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.telemetry.TelemetryManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.coroutines.coroutineContext
import kotlin.random.Random

class OpenRungVpnService : VpnService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val relaySelector = RelaySelector()
    private var connectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var engine: ProxyEngine? = null
    private var brokerUrl: String = AppConfig.DEFAULT_BROKER_URL
    private var activeRelayId: String? = null

    override fun onCreate() {
        super.onCreate()
        OpenRungStatusStore.initialize(applicationContext)
        TelemetryManager.initialize(applicationContext)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CONNECT -> {
                val brokerUrl = intent.getStringExtra(EXTRA_BROKER_URL).orEmpty()
                val targetCountry = intent.getStringExtra(EXTRA_TARGET_COUNTRY)?.takeIf { it.isNotBlank() }
                val targetRelayId = intent.getStringExtra(EXTRA_TARGET_RELAY_ID)?.takeIf { it.isNotBlank() }
                heartbeatJob?.cancel()
                connectJob?.cancel()
                connectJob = serviceScope.launch {
                    connect(brokerUrl.ifBlank { AppConfig.DEFAULT_BROKER_URL }, targetCountry, targetRelayId)
                }
            }
            ACTION_DISCONNECT -> disconnect()
        }
        return START_STICKY
    }

    override fun onRevoke() {
        disconnect()
        super.onRevoke()
    }

    override fun onDestroy() {
        disconnect()
        // Cancel the scope so its Job, its Main.immediate dispatcher, and any in-flight
        // coroutines (connect, heartbeat, the disconnect() telemetry flush) don't outlive this
        // service instance. Mirrors OpenRungVpnModule.invalidate(). This supersedes the explicit
        // connectJob cancel (scope cancellation cancels all children). The on-destroy telemetry
        // flush is best-effort — the outbox retries anything dropped here on the next session.
        serviceScope.cancel()
        super.onDestroy()
    }

    private suspend fun connect(
        brokerUrl: String,
        targetCountry: String? = null,
        targetRelayId: String? = null,
    ) {
        this.brokerUrl = brokerUrl
        // Tear down any existing tunnel first so tapping a different location cleanly switches relays.
        cleanupActiveTunnel()
        // Telemetry/heartbeat go DIRECT to the origin IP, not the Cloudflare-fronted discovery broker,
        // so high-frequency heartbeats don't burn the Workers free-tier quota (see AppConfig).
        val telemetrySession = TelemetryManager.beginSession(applicationContext, AppConfig.TELEMETRY_BROKER_URL)
        var failureStage = "preparing"
        TelemetryManager.record("connection_attempted")
        OpenRungStatusStore.setBrokerUrl(brokerUrl)
        OpenRungStatusStore.clearError()
        OpenRungStatusStore.setStatus(ConnectionStatus.PREPARING, relayLabel = null, lastError = null)
        startForeground(NOTIFICATION_ID, notification(getString(R.string.vpn_notification_preparing)))

        try {
            OpenRungStatusStore.setStatus(ConnectionStatus.CONNECTING)
            OpenRungStatusStore.appendLog(getString(R.string.log_fetching_relays, brokerUrl))
            failureStage = "broker_fetch"
            val brokerEndpoints = AppConfig.brokerCandidates(brokerUrl)
            val (fetch, brokerFetchMs) = coroutineScope {
                val geoLookup = async {
                    runCatching { GeoIpClient().lookup() }.getOrNull()
                }
                val brokerStarted = SystemClock.elapsedRealtime()
                // When targeting a specific country or relay, fetch the full relay set so the
                // target is present (the default page may otherwise miss it). Tries each broker
                // candidate in order so a blocked primary endpoint doesn't take discovery offline.
                val targeted = targetCountry != null || targetRelayId != null
                val result = BrokerClient.firstReachable(
                    candidates = brokerEndpoints,
                    limit = if (targeted) AppConfig.DIRECTORY_RELAY_LIMIT else AppConfig.RELAY_LIMIT,
                    clientId = telemetrySession.clientId,
                    sessionId = telemetrySession.id,
                )
                val elapsed = SystemClock.elapsedRealtime() - brokerStarted
                geoLookup.await()?.let(TelemetryManager::setGeoInfo)
                result to elapsed
            }
            val relayResponse = fetch.response
            // If the configured/primary broker was unreachable and a fallback served the list, pin the
            // rest of this session's broker traffic (telemetry, heartbeats) to the endpoint that worked.
            // The persisted/configured broker URL is left untouched so a user's custom choice survives.
            if (fetch.brokerUrl != brokerUrl) {
                this.brokerUrl = fetch.brokerUrl
                OpenRungStatusStore.appendLog(getString(R.string.log_broker_fallback, fetch.brokerUrl))
            }
            val candidates = relaySelector.orderedCandidates(relayResponse.relays, relayResponse.serverInstant)
            OpenRungStatusStore.appendLog(
                getString(R.string.log_broker_returned, relayResponse.relays.size, candidates.size),
            )
            if (candidates.isEmpty()) {
                throw RelaySelectionException.NoUsableRelay(getString(R.string.error_no_usable_relay))
            }

            val targetedCandidates = if (targetRelayId != null) {
                // A relay picked from the list's expanded per-relay rows: pin that exact relay,
                // never silently fall back to a different one.
                failureStage = "relay_id_filter"
                val matched = candidates.filter { it.id == targetRelayId }
                if (matched.isEmpty()) {
                    throw RelaySelectionException.RelayNotInList(getString(R.string.error_relay_not_available))
                }
                val picked = matched.first()
                OpenRungStatusStore.appendLog(
                    getString(R.string.log_connecting_relay, picked.label.ifBlank { picked.id }),
                )
                matched
            } else if (targetCountry != null) {
                val countryName = CountryGeo.displayName(targetCountry) ?: targetCountry
                OpenRungStatusStore.appendLog(getString(R.string.log_connecting_country, countryName))
                failureStage = "relay_geo_filter"
                filterByCountry(candidates, targetCountry).also {
                    if (it.isEmpty()) {
                        throw RelaySelectionException.NoRelayInCountry(
                            getString(R.string.error_no_relay_in_country, countryName),
                        )
                    }
                }
            } else {
                candidates
            }

            failureStage = "relay_connect"
            val connectedRelay = connectFirstAvailable(targetedCandidates)
            // If a disconnect raced in while we were connecting, don't publish CONNECTED for a
            // tunnel that's being torn down. Stopping the engine is owned by disconnect()/a new
            // connect (both call cleanupActiveTunnel); we just must not commit CONNECTED here.
            coroutineContext.ensureActive()
            val relay = connectedRelay.relay
            activeRelayId = relay.id
            TelemetryManager.markConnected(relay.id)
            OpenRungStatusStore.setStatus(
                ConnectionStatus.CONNECTED,
                relayLabel = null,
                lastError = null,
            )
            updateNotification(getString(R.string.status_connected))
            applyRelayLocation(relay)
            TelemetryManager.record(
                event = "connection_succeeded",
                relayId = relay.id,
                measurements = mapOf(
                    "broker_fetch_ms" to brokerFetchMs,
                    "relay_tcp_ms" to connectedRelay.tcpLatencyMs,
                    "tunnel_start_ms" to connectedRelay.tunnelStartMs,
                    "internet_probe_ms" to connectedRelay.internetProbeMs,
                    "relay_attempts" to connectedRelay.attempts.toLong(),
                ),
            )
            runCatching { TelemetryManager.flush(AppConfig.TELEMETRY_BROKER_URL) }
            // The flush above swallows cancellation (runCatching), so re-check: a disconnect that
            // raced in during it must not leave a heartbeat loop running after teardown.
            coroutineContext.ensureActive()
            startHeartbeatLoop()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            cleanupActiveTunnel()
            val failureReason = FailureClassifier.classify(error)
            val failureDetail = FailureClassifier.detail(error)
            TelemetryManager.record(
                event = "connection_failed",
                attributes = buildMap {
                    put("failure_stage", failureStage)
                    // Kept alongside failure_reason for dashboard continuity with older app versions.
                    put("error_type", error::class.java.simpleName)
                    if (failureReason.isNotBlank()) put("failure_reason", failureReason)
                    if (failureDetail.isNotBlank()) put("failure_detail", failureDetail)
                },
            )
            TelemetryManager.endSession("connection_failed")
            runCatching { TelemetryManager.flush(AppConfig.TELEMETRY_BROKER_URL) }
            OpenRungStatusStore.fail(error.message ?: getString(R.string.error_vpn_connection_failed))
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private suspend fun connectFirstAvailable(candidates: List<RelayDescriptor>): ConnectedRelay {
        var lastError: Throwable? = null
        for ((index, relay) in candidates.withIndex()) {
            try {
                OpenRungStatusStore.appendLog(
                    getString(R.string.log_trying_relay, relay.id, relay.publicHost, relay.publicPort),
                )
                OpenRungStatusStore.appendLog(getString(R.string.log_checking_relay_reachability))
                val tcpLatencyMs = try {
                    RelayReachability.checkTcp(relay)
                } catch (error: CancellationException) {
                    // A racing disconnect cancels this coroutine; let cancellation propagate instead
                    // of masking it as an "unreachable" failure, which would keep trying relays and
                    // could bring a tunnel up after teardown.
                    throw error
                } catch (error: Throwable) {
                    throw IllegalStateException(
                        getString(R.string.error_relay_unreachable, relay.publicHost, relay.publicPort),
                        error,
                    )
                }
                val config = SingBoxConfiguration(relay = relay).encodedJsonString()
                val proxyEngine = ProxyEngineFactory.create()
                val tunnelStarted = SystemClock.elapsedRealtime()
                // Tag an engine start/liveness failure as EngineStartException so it classifies as
                // process_exited (the embedded-engine analogue of the Go clients' sing-box subprocess
                // dying). The original error is kept as the cause so a more specific signal in its
                // chain still wins over process_exited.
                try {
                    proxyEngine.start(
                        relay = relay,
                        configJson = config,
                        vpnService = this,
                    )
                } catch (error: CancellationException) {
                    throw error
                } catch (error: Throwable) {
                    throw EngineStartException(error.message, error)
                }
                val tunnelStartMs = SystemClock.elapsedRealtime() - tunnelStarted
                engine = proxyEngine
                OpenRungStatusStore.appendLog(getString(R.string.log_verifying_internet))
                val internetProbe = InternetProbe(applicationContext).verify()
                OpenRungStatusStore.appendLog(
                    getString(R.string.log_internet_verified, internetProbe.durationMs),
                )
                return ConnectedRelay(
                    relay = relay,
                    tcpLatencyMs = tcpLatencyMs,
                    tunnelStartMs = tunnelStartMs,
                    internetProbeMs = internetProbe.durationMs,
                    attempts = index + 1,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                lastError = error
                val attemptReason = FailureClassifier.classify(error)
                val attemptDetail = FailureClassifier.detail(error)
                TelemetryManager.record(
                    event = "relay_attempt_failed",
                    relayId = relay.id,
                    attributes = buildMap {
                        // Kept alongside failure_reason for continuity with older app versions.
                        put("error_type", error::class.java.simpleName)
                        if (attemptReason.isNotBlank()) put("failure_reason", attemptReason)
                        if (attemptDetail.isNotBlank()) put("failure_detail", attemptDetail)
                    },
                    measurements = mapOf("attempt" to (index + 1).toLong()),
                )
                OpenRungStatusStore.appendLog(
                    getString(
                        R.string.log_relay_failed,
                        relay.id,
                        error.message ?: error::class.java.simpleName,
                    ),
                )
                cleanupActiveTunnel()
            }
        }

        // Preserve lastError as the cause so connection_failed classifies on the real root cause
        // (timeout, connection_refused, process_exited, …) instead of this generic wrapper.
        throw IllegalStateException(
            getString(
                R.string.error_all_relays_failed,
                lastError?.message ?: getString(R.string.error_unknown),
            ),
            lastError,
        )
    }

    /**
     * Keeps only candidates whose broker-served country matches [countryCode]. Relays the broker
     * hasn't geolocated yet are excluded so a targeted connect never silently lands in the wrong
     * country. The broker geolocates each relay's real exit — the app never geolocates relay IPs
     * itself (a tunnel relay's publicHost would give the hub's location, not the exit's).
     */
    private fun filterByCountry(
        candidates: List<RelayDescriptor>,
        countryCode: String,
    ): List<RelayDescriptor> {
        val target = countryCode.trim().uppercase()
        return candidates.filter { it.countryCode.trim().uppercase() == target }
    }

    private fun disconnect() {
        heartbeatJob?.cancel()
        heartbeatJob = null
        OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTING)
        connectJob?.cancel()
        cleanupActiveTunnel()
        activeRelayId?.let {
            TelemetryManager.record("tunnel_stopped", relayId = it)
        }
        activeRelayId = null
        TelemetryManager.endSession("disconnect")
        serviceScope.launch {
            runCatching { TelemetryManager.flush(AppConfig.TELEMETRY_BROKER_URL) }
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        OpenRungStatusStore.setStatus(ConnectionStatus.DISCONNECTED, relayLabel = null, lastError = null)
        stopSelf()
    }

    /**
     * Publishes the relay's broker-served location and shows only that location (never the raw
     * IP). Falls back to a generic label while the broker hasn't resolved the relay's geo yet.
     */
    private fun applyRelayLocation(relay: RelayDescriptor) {
        val location = relay.locationLabel().ifBlank { getString(R.string.relay_location_unknown) }
        OpenRungStatusStore.setRelayLabel(location)
        updateNotification(getString(R.string.vpn_notification_connected, location))
        recordRecentNode(relay)
    }

    /** Adds the connected relay's broker-served country to the "Recents" row (best-effort). */
    private fun recordRecentNode(relay: RelayDescriptor) {
        val code = relay.countryCode.trim().uppercase()
        if (code.isBlank()) return
        val centroid = CountryGeo.centroid(code)
        OpenRungStatusStore.recordRecent(
            RecentNode(
                countryCode = code,
                label = relay.locationLabel().ifBlank { centroid?.name ?: code },
                latitude = centroid?.latitude ?: relay.latitude ?: 0.0,
                longitude = centroid?.longitude ?: relay.longitude ?: 0.0,
            ),
        )
    }

    private fun startHeartbeatLoop() {
        heartbeatJob?.cancel()
        heartbeatJob = serviceScope.launch {
            while (isActive) {
                runCatching { TelemetryManager.sendHeartbeat() }
                delay(Random.nextLong(HEARTBEAT_MIN_DELAY_MS, HEARTBEAT_MAX_DELAY_MS + 1))
            }
        }
    }

    private fun cleanupActiveTunnel() {
        engine?.stop()
        engine = null
    }

    private data class ConnectedRelay(
        val relay: RelayDescriptor,
        val tcpLatencyMs: Long,
        val tunnelStartMs: Long,
        val internetProbeMs: Long,
        val attempts: Int,
    )

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            getString(R.string.vpn_notification_channel),
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    private fun updateNotification(message: String) {
        val manager = getSystemService(NotificationManager::class.java)
        manager.notify(NOTIFICATION_ID, notification(message))
    }

    private fun notification(message: String): Notification {
        val launchIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_vpn)
            .setContentTitle(getString(R.string.vpn_notification_title))
            .setContentText(message)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .build()
    }

    companion object {
        private const val ACTION_CONNECT = "com.openrung.action.CONNECT"
        private const val ACTION_DISCONNECT = "com.openrung.action.DISCONNECT"
        private const val EXTRA_BROKER_URL = "broker_url"
        private const val EXTRA_TARGET_COUNTRY = "target_country"
        private const val EXTRA_TARGET_RELAY_ID = "target_relay_id"
        private const val NOTIFICATION_CHANNEL_ID = "openrung_vpn"
        private const val NOTIFICATION_ID = 2001
        internal const val HEARTBEAT_MIN_DELAY_MS = 50_000L
        internal const val HEARTBEAT_MAX_DELAY_MS = 70_000L

        fun connectIntent(
            context: Context,
            brokerUrl: String,
            targetCountry: String? = null,
            targetRelayId: String? = null,
        ): Intent =
            Intent(context, OpenRungVpnService::class.java).apply {
                action = ACTION_CONNECT
                putExtra(EXTRA_BROKER_URL, brokerUrl)
                targetCountry?.let { putExtra(EXTRA_TARGET_COUNTRY, it) }
                targetRelayId?.let { putExtra(EXTRA_TARGET_RELAY_ID, it) }
            }

        fun disconnectIntent(context: Context): Intent =
            Intent(context, OpenRungVpnService::class.java).apply {
                action = ACTION_DISCONNECT
            }
    }
}
