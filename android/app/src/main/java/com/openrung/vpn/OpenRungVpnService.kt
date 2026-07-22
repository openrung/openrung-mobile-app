package com.openrung.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
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
import com.openrung.model.WssFrontDescriptor
import com.openrung.net.BrokerClient
import com.openrung.net.GeoIpClient
import com.openrung.net.InternetProbe
import com.openrung.net.NatPunchClient
import com.openrung.net.NatPunchResult
import com.openrung.net.NatPunchSession
import com.openrung.net.NativeWssFrontSetValidator
import com.openrung.net.PhysicalNetworkEpochMonitor
import com.openrung.net.RelayRanker
import com.openrung.net.RelayReachability
import com.openrung.net.SingBoxConfiguration
import com.openrung.net.WssClient
import com.openrung.net.WssSession
import com.openrung.net.WssTicketClient
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.telemetry.TelemetryManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
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
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.io.IOException
import java.net.InetAddress
import java.net.URL
import java.time.Instant
import kotlin.coroutines.coroutineContext
import kotlin.random.Random

class OpenRungVpnService : VpnService() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val relaySelector = RelaySelector()
    private val punchRecoveryCircuitBreaker = PunchRecoveryCircuitBreaker()
    private val wssFallbackPolicy = WssFallbackPolicy(NativeWssFrontSetValidator)
    private var connectJob: Job? = null
    private var heartbeatJob: Job? = null
    private var engineMonitorJob: Job? = null
    private var punchMonitorJob: Job? = null
    private var wssMonitorJob: Job? = null
    private var engine: ProxyEngine? = null
    private var punchSession: NatPunchSession? = null
    private var wssSession: WssSession? = null
    private var physicalNetworkMonitor: PhysicalNetworkEpochMonitor? = null
    private var brokerUrl: String = AppConfig.DEFAULT_BROKER_URL
    private var activeRelayId: String? = null
    private var requestedTargetCountry: String? = null
    private var requestedTargetRelayId: String? = null

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
                engineMonitorJob?.cancel()
                engineMonitorJob = null
                punchMonitorJob?.cancel()
                punchMonitorJob = null
                wssMonitorJob?.cancel()
                wssMonitorJob = null
                connectJob?.cancel()
                // A user-initiated connect starts a new recovery epoch. Recursive recovery calls
                // connect() directly and deliberately keep the breaker state that led to them.
                punchRecoveryCircuitBreaker.reset()
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
        requestedTargetCountry = targetCountry
        requestedTargetRelayId = targetRelayId
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
                // target is present (the default page may otherwise miss it). A genuine user
                // override is tried strictly first with its full attempt timeout; the defaults
                // race with a staggered start, so a blocked front costs one DISCOVERY_STAGGER_MS
                // of extra latency instead of taking discovery offline.
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
            // If a fallback front won discovery — a genuine override is beaten only by FAILING
            // outright (it is tried strictly first); a default primary also when merely slower than
            // its head start — pin the rest of this session's broker traffic (telemetry, heartbeats)
            // to the endpoint that worked. The persisted/configured broker URL is left untouched so a
            // user's custom choice survives.
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

            // Reorder (never shrink) the ladder by this client's measured TCP latency. Broker
            // order already scores load headroom / success rate / latency / speed from the
            // broker's vantage, so RelayRanker only overrides it across latency buckets — within
            // a bucket the broker's load balancing still decides. A pinned relay skips ranking:
            // there is exactly one candidate and the user chose it.
            val rankedCandidates = if (targetRelayId == null && targetedCandidates.size > 1) {
                failureStage = "relay_rank"
                OpenRungStatusStore.appendLog(
                    getString(
                        R.string.log_rank_probing,
                        minOf(targetedCandidates.size, RelayRanker.DEFAULT_MAX_PROBES),
                    ),
                )
                RelayRanker.rankByTcpLatency(targetedCandidates)
            } else {
                targetedCandidates.map { RelayRanker.RankedRelay(it, null) }
            }

            failureStage = "relay_connect"
            val connectedRelay = connectFirstAvailable(rankedCandidates.map { it.relay })
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
                attributes = buildMap {
                    put("transport", connectedRelay.accessTransport)
                    connectedRelay.frontId?.let { put("front_id", it) }
                },
                measurements = buildMap {
                    put("broker_fetch_ms", brokerFetchMs)
                    connectedRelay.tcpLatencyMs?.let { put("relay_tcp_ms", it) }
                    put("tunnel_start_ms", connectedRelay.tunnelStartMs)
                    put("internet_probe_ms", connectedRelay.internetProbeMs)
                    put("relay_attempts", connectedRelay.attempts.toLong())
                    // Rank observability: where the connected relay sat in broker order before
                    // ranking, and its probe latency when it was probed — the pair that shows
                    // whether client-side ranking actually beats broker order on tunnel_start_ms.
                    put(
                        "relay_broker_index",
                        targetedCandidates.indexOfFirst { it.id == relay.id }.toLong(),
                    )
                    rankedCandidates.firstOrNull { it.relay.id == relay.id }
                        ?.probeMs
                        ?.let { put("relay_probe_ms", it) }
                },
            )
            // Promote liveness monitoring before the best-effort telemetry upload. A slow upload
            // must never leave a newly-dead direct path claiming CONNECTED for its HTTP timeout.
            coroutineContext.ensureActive()
            startHeartbeatLoop()
            startTunnelEngineMonitor(relay, coroutineContext[Job])
            startPunchMonitor(relay, coroutineContext[Job])
            startWssMonitor(relay, coroutineContext[Job])
            // This is deliberately the final operation. runCatching can swallow cancellation, so
            // no stateful work may follow it; disconnect/recovery own the already-running jobs.
            runCatching { TelemetryManager.flush(AppConfig.TELEMETRY_BROKER_URL) }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            heartbeatJob?.cancel()
            heartbeatJob = null
            val currentJob = coroutineContext[Job]
            if (engineMonitorJob !== currentJob) engineMonitorJob?.cancel()
            if (engineMonitorJob !== currentJob) engineMonitorJob = null
            if (punchMonitorJob !== currentJob) punchMonitorJob?.cancel()
            punchMonitorJob = null
            if (wssMonitorJob !== currentJob) wssMonitorJob?.cancel()
            if (wssMonitorJob !== currentJob) wssMonitorJob = null
            cleanupActiveTunnel()
            activeRelayId = null
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
                return wssFallbackPolicy.connect(
                    relay = relay,
                    attemptDirect = {
                        attemptDirectCandidate(relay, index + 1)
                    },
                    attemptWss = { front ->
                        attemptWssCandidate(relay, front, index + 1)
                    },
                    onDirectFallback = { directFailure ->
                        // A failed post-ready direct attempt can still own a libbox engine. Stop it
                        // before dialing the relay's loopback WSS adapter. Record this one genuine
                        // direct failure exactly once; later ticket/CDN failures are transport-only.
                        cleanupActiveTunnel()
                        recordRelayAttemptFailure(relay, directFailure, index + 1)
                        TelemetryManager.record(
                            event = "transport_fallback",
                            relayId = relay.id,
                            attributes = buildMap {
                                put("from_transport", ACCESS_TRANSPORT_DIRECT)
                                put("to_transport", ACCESS_TRANSPORT_WSS)
                                FailureClassifier.classify(directFailure).takeIf { it.isNotBlank() }
                                    ?.let { put("failure_reason", it) }
                            },
                        )
                        OpenRungStatusStore.appendLog(getString(R.string.log_wss_fallback))
                    },
                    onWssFailure = { front, error ->
                        cleanupActiveTunnel()
                        recordWssTransportFailure(relay, front, error)
                        OpenRungStatusStore.appendLog(
                            getString(R.string.log_wss_front_failed, front.id, error.stage),
                        )
                    },
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: LocalTunnelException) {
                // The engine, configuration, permission and Android platform are common to every
                // relay. They are not evidence against this relay and must never mint another ticket.
                cleanupActiveTunnel()
                throw error
            } catch (error: Throwable) {
                lastError = error
                if (!relayFailureAlreadyRecorded(error)) {
                    recordRelayAttemptFailure(relay, error, index + 1)
                }
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

    /** Existing direct Reality path, with only remote TCP/post-ready data failures typed for WSS. */
    private suspend fun attemptDirectCandidate(relay: RelayDescriptor, attempt: Int): ConnectedRelay {
        ensureLocalTunnelPreconditions(relay)
        OpenRungStatusStore.appendLog(
            getString(R.string.log_trying_relay, relay.id, relay.publicHost, relay.publicPort),
        )
        OpenRungStatusStore.appendLog(getString(R.string.log_checking_relay_reachability))
        val tcpLatencyMs = try {
            RelayReachability.checkTcp(relay)
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (!isGenuineRemoteDataPathFailure(error)) {
                throw LocalTunnelException("direct_socket", error)
            }
            throw DirectPathException("tcp", error)
        }

        val punched = attemptDirectPunch(relay)
        if (punched != null) {
            try {
                return startTunnel(
                    relay = relay,
                    config = SingBoxConfiguration(
                        relay = relay,
                        bridgeHost = punched.bridgeHost,
                        bridgePort = punched.bridgePort,
                    ),
                    tcpLatencyMs = tcpLatencyMs,
                    attempt = attempt,
                    accessTransport = ACCESS_TRANSPORT_PUNCH,
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: LocalTunnelException) {
                throw error
            } catch (error: Throwable) {
                // A live punched QUIC path can still fail to carry Reality. Preserve the existing
                // same-relay RelayHub rung, but never retry local engine/platform failures.
                TelemetryManager.record(
                    event = "punch_fallback",
                    relayId = relay.id,
                    attributes = buildMap {
                        FailureClassifier.classify(error).takeIf { it.isNotBlank() }
                            ?.let { put("failure_reason", it) }
                        FailureClassifier.detail(error).takeIf { it.isNotBlank() }
                            ?.let { put("failure_detail", it) }
                    },
                )
                OpenRungStatusStore.appendLog(getString(R.string.log_punch_transport_failed))
                cleanupActiveTunnel()
            }
        }

        return startTunnel(
            relay = relay,
            config = SingBoxConfiguration(relay = relay),
            tcpLatencyMs = tcpLatencyMs,
            attempt = attempt,
            accessTransport = ACCESS_TRANSPORT_DIRECT,
        )
    }

    /** Fail local setup before a raw relay failure can authorize any ticket request. */
    private fun ensureLocalTunnelPreconditions(relay: RelayDescriptor) {
        if (VpnService.prepare(this) != null) {
            throw LocalTunnelException(
                "vpn_permission",
                SecurityException("Android VPN permission is not granted"),
            )
        }
        if (!ProxyEngineFactory.isAvailable()) {
            throw LocalTunnelException(
                "engine_unavailable",
                IllegalStateException("libbox engine is not linked"),
            )
        }
        try {
            // Check both direct Reality and loopback-adapter graph shapes. Libbox.checkConfig is a
            // pure parse/construct/close preflight; it starts no service, opens no TUN and performs
            // no network I/O. The actual adapter port is immaterial to graph validation.
            listOf(
                SingBoxConfiguration(relay).encodedJsonString(),
                SingBoxConfiguration(
                    relay = relay,
                    bridgeHost = "127.0.0.1",
                    bridgePort = 1,
                ).encodedJsonString(),
            ).forEach(ProxyEngineFactory::preflight)
        } catch (error: Throwable) {
            throw LocalTunnelException("configuration", error)
        }
    }

    /** Obtains one front-bound ticket, dials wsscore, then reuses the existing Reality client. */
    private suspend fun attemptWssCandidate(
        relay: RelayDescriptor,
        front: WssFrontDescriptor,
        attempt: Int,
    ): ConnectedRelay {
        val telemetrySession = TelemetryManager.activeSession()
        val ticket = try {
            WssTicketClient.requestWithFailover(
                brokerUrls = wssTicketBrokerFronts(),
                relayId = relay.id,
                frontId = front.id,
                clientId = telemetrySession?.clientId,
                sessionId = telemetrySession?.id,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (isLocalPlatformFailure(error)) {
                throw LocalTunnelException("ticket_client", error)
            }
            throw WssTransportException("ticket", front.id, error)
        }
        if (ticket.url != front.url) {
            throw WssTransportException(
                "ticket_binding",
                front.id,
                IOException("WSS ticket URL does not match the signed relay front"),
            )
        }
        if (!ticket.expiresAt.isAfter(Instant.now())) {
            throw WssTransportException(
                "ticket_expired",
                front.id,
                IOException("WSS ticket is already expired"),
            )
        }

        val session = try {
            WssClient.create(this, front.url, ticket.ticket)
        } catch (error: Throwable) {
            throw LocalTunnelException("wss_client", error)
        }
        wssSession = session
        val result = try {
            session.connect()
        } catch (error: CancellationException) {
            closeWssSession(session)
            throw error
        } catch (error: Throwable) {
            closeWssSession(session)
            if (isLocalPlatformFailure(error)) {
                throw LocalTunnelException("wss_client", error)
            }
            throw WssTransportException("wss_handshake", front.id, error)
        }
        coroutineContext.ensureActive()
        if (!result.succeeded) {
            closeWssSession(session)
            val failure = IOException(
                result.errorText.ifBlank { "WSS connection failed (${result.reason.ifBlank { "unknown" }})" },
            )
            when (result.reason) {
                "protect" -> throw LocalTunnelException("wss_socket_protect", failure)
                "client", "front", "adapter" -> throw LocalTunnelException("wss_client", failure)
            }
            throw WssTransportException("wss_handshake", front.id, failure)
        }
        if (!isSafeLoopbackEndpoint(result.bridgeHost, result.bridgePort)) {
            closeWssSession(session)
            throw LocalTunnelException(
                "local_adapter",
                IOException("WSS adapter returned no safe loopback endpoint"),
            )
        }

        OpenRungStatusStore.appendLog(getString(R.string.log_wss_connected, front.id))
        return startTunnel(
            relay = relay,
            config = SingBoxConfiguration(
                relay = relay,
                bridgeHost = result.bridgeHost,
                bridgePort = result.bridgePort,
            ),
            tcpLatencyMs = null,
            attempt = attempt,
            accessTransport = ACCESS_TRANSPORT_WSS,
            frontId = front.id,
        )
    }

    private fun recordRelayAttemptFailure(relay: RelayDescriptor, error: Throwable, attempt: Int) {
        val attemptReason = FailureClassifier.classify(error)
        val attemptDetail = FailureClassifier.detail(error)
        TelemetryManager.record(
            event = "relay_attempt_failed",
            relayId = relay.id,
            attributes = buildMap {
                put("error_type", error::class.java.simpleName)
                if (attemptReason.isNotBlank()) put("failure_reason", attemptReason)
                if (attemptDetail.isNotBlank()) put("failure_detail", attemptDetail)
            },
            measurements = mapOf("attempt" to attempt.toLong()),
        )
    }

    private fun recordWssTransportFailure(
        relay: RelayDescriptor,
        front: WssFrontDescriptor,
        error: WssTransportException,
    ) {
        TelemetryManager.record(
            event = "transport_failed",
            relayId = relay.id,
            attributes = buildMap {
                put("transport", ACCESS_TRANSPORT_WSS)
                put("failure_stage", error.stage)
                put("front_id", front.id)
                FailureClassifier.classify(error).takeIf { it.isNotBlank() }
                    ?.let { put("failure_reason", it) }
            },
        )
    }

    private fun wssTicketBrokerFronts(): List<String> = buildList {
        add(brokerUrl)
        addAll(AppConfig.DEFAULT_BROKER_URLS)
    }.map(String::trim).filter(String::isNotEmpty).distinct()

    private fun isSafeLoopbackEndpoint(host: String, port: Int): Boolean {
        if (port !in 1..65_535) return false
        return runCatching { InetAddress.getByName(host).isLoopbackAddress }.getOrDefault(false)
    }

    /** Unchecked/platform failures are never evidence that a remote relay path is blocked. */
    private fun isLocalPlatformFailure(error: Throwable): Boolean {
        if (FailureClassifier.classify(error) == "permission_denied") return true
        val seen = HashSet<Throwable>()
        var current: Throwable? = error
        while (current != null && seen.add(current)) {
            if (current is RuntimeException || current is LinkageError) return true
            current = current.cause
        }
        return false
    }

    /** Attempts the signaling/UDP/QUIC path and leaves a live loopback bridge on success. */
    private suspend fun attemptDirectPunch(relay: RelayDescriptor): NatPunchResult? {
        if (!relay.punchCapable) return null
        if (!punchRecoveryCircuitBreaker.allowsDirectPunch(relay.id)) {
            TelemetryManager.record(
                event = "punch_skipped",
                relayId = relay.id,
                attributes = mapOf("reason" to "recovery_circuit_open"),
            )
            return null
        }

        TelemetryManager.record("punch_attempted", relayId = relay.id)
        OpenRungStatusStore.appendLog(getString(R.string.log_punch_attempting))
        val session = NatPunchClient.create(this, relay)
        if (session == null) {
            recordPunchFailure(relay, reason = "endpoint", natClass = "", detail = "")
            OpenRungStatusStore.appendLog(getString(R.string.log_punch_failed, "endpoint"))
            return null
        }

        punchSession = session
        val result = try {
            session.establish()
        } catch (error: CancellationException) {
            closePunchSession(session)
            throw error
        } catch (error: Throwable) {
            closePunchSession(session)
            recordPunchFailure(
                relay,
                reason = "client",
                natClass = "",
                detail = error.message.orEmpty(),
            )
            OpenRungStatusStore.appendLog(getString(R.string.log_punch_failed, "client"))
            return null
        }
        try {
            coroutineContext.ensureActive()
        } catch (error: CancellationException) {
            closePunchSession(session)
            throw error
        }

        if (!result.succeeded) {
            closePunchSession(session)
            val reason = result.reason.ifBlank { "unknown" }
            recordPunchFailure(relay, reason, result.natClass, result.errorText)
            OpenRungStatusStore.appendLog(getString(R.string.log_punch_failed, reason))
            return null
        }

        TelemetryManager.record(
            event = "punch_succeeded",
            relayId = relay.id,
            attributes = buildMap {
                if (result.natClass.isNotBlank()) put("nat_class", result.natClass)
            },
            measurements = mapOf("punch_rtt_ms" to result.rttMillis),
        )
        OpenRungStatusStore.appendLog(
            getString(
                R.string.log_punch_succeeded,
                result.peerIp,
                result.natClass.ifBlank { "unknown" },
            ),
        )
        return result
    }

    private fun recordPunchFailure(
        relay: RelayDescriptor,
        reason: String,
        natClass: String,
        detail: String,
    ) {
        TelemetryManager.record(
            event = "punch_failed",
            relayId = relay.id,
            attributes = buildMap {
                put("reason", reason)
                if (natClass.isNotBlank()) put("nat_class", natClass)
                if (detail.isNotBlank()) put("failure_detail", detail.take(256))
            },
        )
    }

    private suspend fun startTunnel(
        relay: RelayDescriptor,
        config: SingBoxConfiguration,
        tcpLatencyMs: Long?,
        attempt: Int,
        accessTransport: String,
        frontId: String? = null,
    ): ConnectedRelay {
        val configJson = try {
            config.encodedJsonString()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw LocalTunnelException("configuration", error)
        }
        val proxyEngine = try {
            ProxyEngineFactory.create()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            throw LocalTunnelException("engine_create", error)
        }
        val tunnelStarted = SystemClock.elapsedRealtime()
        // Configuration, engine construction, VPN permission, and platform startup failures are
        // local. Stop a partially-started instance and keep them out of both WSS fallback and
        // relay-health accounting. EngineStartException preserves the existing process_exited
        // telemetry classification inside the local wrapper.
        try {
            proxyEngine.start(
                relay = relay,
                configJson = configJson,
                vpnService = this,
            )
        } catch (error: CancellationException) {
            proxyEngine.stop()
            throw error
        } catch (error: Throwable) {
            proxyEngine.stop()
            throw LocalTunnelException(
                "engine_start",
                EngineStartException(error.message, error),
            )
        }
        val tunnelStartMs = SystemClock.elapsedRealtime() - tunnelStarted
        engine = proxyEngine
        OpenRungStatusStore.appendLog(getString(R.string.log_verifying_internet))
        val internetProbe = try {
            awaitStartupProbeOrEngineStop(
                probe = { InternetProbe(applicationContext).verify() },
                awaitUnexpectedEngineStop = proxyEngine::awaitUnexpectedStop,
            )
        } catch (error: CancellationException) {
            throw error
        } catch (error: Throwable) {
            if (error is LocalTunnelException) throw error
            if (!isGenuineRemoteDataPathFailure(error)) {
                throw LocalTunnelException("internet_probe", error)
            }
            if (accessTransport == ACCESS_TRANSPORT_WSS) {
                throw WssTransportException(
                    stage = "internet_probe",
                    frontId = checkNotNull(frontId) { "WSS transport requires a front id" },
                    cause = error,
                )
            }
            throw DirectPathException("internet_probe", error)
        }
        OpenRungStatusStore.appendLog(
            getString(R.string.log_internet_verified, internetProbe.durationMs),
        )
        return ConnectedRelay(
            relay = relay,
            tcpLatencyMs = tcpLatencyMs,
            tunnelStartMs = tunnelStartMs,
            internetProbeMs = internetProbe.durationMs,
            attempts = attempt,
            accessTransport = accessTransport,
            frontId = frontId,
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
        engineMonitorJob?.cancel()
        engineMonitorJob = null
        punchMonitorJob?.cancel()
        punchMonitorJob = null
        wssMonitorJob?.cancel()
        wssMonitorJob = null
        punchRecoveryCircuitBreaker.reset()
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

    /**
     * Watches the local libbox service independently of every access transport. A local engine
     * crash is terminal: it must never be converted into relay failover or a new WSS ticket.
     */
    private fun startTunnelEngineMonitor(relay: RelayDescriptor, ownerJob: Job?) {
        val tunnelEngine = engine ?: throw LocalTunnelException(
            "engine_monitor",
            IllegalStateException("connected tunnel has no active engine"),
        )
        if (engineMonitorJob !== ownerJob) engineMonitorJob?.cancel()
        engineMonitorJob = serviceScope.launch {
            val reason = try {
                tunnelEngine.awaitUnexpectedStop()
            } catch (error: CancellationException) {
                return@launch
            }
            if (engine !== tunnelEngine || activeRelayId != relay.id) return@launch
            try {
                terminateForActiveLocalFailure(
                    relay = relay,
                    error = LocalTunnelException(
                        "active_tunnel_engine",
                        EngineStartException(reason, null),
                    ),
                    userMessage = getString(R.string.error_tunnel_engine_stopped),
                    logMessage = getString(R.string.log_tunnel_engine_stopped),
                )
            } finally {
                if (engineMonitorJob === coroutineContext[Job]) engineMonitorJob = null
            }
        }
    }

    private suspend fun terminateForActiveLocalFailure(
        relay: RelayDescriptor,
        error: LocalTunnelException,
        userMessage: String = getString(R.string.error_vpn_connection_failed),
        logMessage: String = error.message ?: getString(R.string.error_vpn_connection_failed),
    ) {
        if (activeRelayId != relay.id) return
        OpenRungStatusStore.appendLog(logMessage.take(256))
        TelemetryManager.record(
            event = "connection_failed",
            relayId = relay.id,
            attributes = buildMap {
                put("failure_stage", error.stage)
                FailureClassifier.classify(error).takeIf { it.isNotBlank() }
                    ?.let { put("failure_reason", it) }
                FailureClassifier.detail(error).takeIf { it.isNotBlank() }
                    ?.let { put("failure_detail", it.take(256)) }
            },
        )
        val currentJob = coroutineContext[Job]
        heartbeatJob?.cancel()
        heartbeatJob = null
        if (engineMonitorJob !== currentJob) engineMonitorJob?.cancel()
        if (engineMonitorJob !== currentJob) engineMonitorJob = null
        if (punchMonitorJob !== currentJob) punchMonitorJob?.cancel()
        if (punchMonitorJob !== currentJob) punchMonitorJob = null
        if (wssMonitorJob !== currentJob) wssMonitorJob?.cancel()
        if (wssMonitorJob !== currentJob) wssMonitorJob = null
        cleanupActiveTunnel()
        activeRelayId = null
        TelemetryManager.endSession("connection_failed")
        runCatching { TelemetryManager.flush(AppConfig.TELEMETRY_BROKER_URL) }
        OpenRungStatusStore.fail(userMessage)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Watches both the native QUIC connection and end-to-end traffic after CONNECTED. NAT mappings
     * are tied to the underlying network, while a relay-side Xray/stream failure can leave QUIC
     * itself alive. Either signal retires the dead path and reruns discovery so the app can re-punch
     * with fresh metadata or use RelayHub.
     */
    private fun startPunchMonitor(relay: RelayDescriptor, ownerJob: Job?) {
        val session = punchSession ?: return
        if (punchMonitorJob !== ownerJob) punchMonitorJob?.cancel()
        punchRecoveryCircuitBreaker.markDirectConnected(relay.id, SystemClock.elapsedRealtime())
        punchMonitorJob = serviceScope.launch {
            val failure = try {
                awaitPunchFailure(session)
            } catch (error: CancellationException) {
                return@launch
            } catch (error: LocalTunnelException) {
                if (punchSession === session && activeRelayId == relay.id) {
                    terminateForActiveLocalFailure(relay, error)
                }
                if (punchMonitorJob === coroutineContext[Job]) punchMonitorJob = null
                return@launch
            }
            val reason = failure.reason
            val pathLostAtMs = SystemClock.elapsedRealtime()
            // Close and callback can race across the Go/Java boundary. Only the still-current,
            // already-promoted session is allowed to initiate recovery.
            if (punchSession !== session || activeRelayId != relay.id) return@launch
            if (terminateIfActiveEngineStopped(relay)) {
                if (punchMonitorJob === coroutineContext[Job]) punchMonitorJob = null
                return@launch
            }

            OpenRungStatusStore.appendLog(getString(R.string.log_punch_path_lost, reason.take(160)))
            TelemetryManager.record(
                event = "punch_path_lost",
                relayId = relay.id,
                attributes = mapOf("reason" to reason.take(256)),
            )
            try {
                val country = requestedTargetCountry
                val relayID = requestedTargetRelayId
                // Publish the state transition before stopping the engine. Recovery may involve
                // network timeouts, and the UI must never claim CONNECTED while no TUN is active.
                OpenRungStatusStore.setStatus(
                    ConnectionStatus.CONNECTING,
                    relayLabel = null,
                    lastError = null,
                )
                updateNotification(getString(R.string.status_connecting))
                heartbeatJob?.cancel()
                heartbeatJob = null
                engineMonitorJob?.cancel()
                engineMonitorJob = null
                cleanupActiveTunnel()
                activeRelayId = null
                coroutineContext.ensureActive()
                val physicalNetworkWasUnavailable =
                    failure.waitForPhysicalNetwork && !physicalNetworkAlive()
                val recoveryDecision = punchRecoveryCircuitBreaker.onDirectPathLost(
                    relayId = relay.id,
                    nowElapsedMs = pathLostAtMs,
                    countTowardBreaker = !physicalNetworkWasUnavailable,
                )
                when (recoveryDecision) {
                    is PunchRecoveryDecision.RetryDirect -> {
                        if (recoveryDecision.delayMs > 0) {
                            OpenRungStatusStore.appendLog(
                                getString(
                                    R.string.log_punch_recovery_scheduled,
                                    recoveryDecision.rapidFailureCount,
                                    recoveryDecision.delayMs.toDisplaySeconds(),
                                ),
                            )
                        }
                    }
                    is PunchRecoveryDecision.UseRelayHub -> {
                        OpenRungStatusStore.appendLog(
                            getString(
                                R.string.log_punch_circuit_open,
                                recoveryDecision.delayMs.toDisplaySeconds(),
                            ),
                        )
                        TelemetryManager.record(
                            event = "punch_fallback",
                            relayId = relay.id,
                            attributes = mapOf(
                                "failure_reason" to "unstable_direct_path",
                                "failure_detail" to reason.take(256),
                            ),
                            measurements = mapOf(
                                "rapid_failure_count" to recoveryDecision.rapidFailureCount.toLong(),
                                "direct_uptime_ms" to recoveryDecision.directUptimeMs,
                                "recovery_delay_ms" to recoveryDecision.delayMs,
                            ),
                        )
                    }
                }
                TelemetryManager.endSession("punch_path_lost")
                coroutineContext.ensureActive()
                if (physicalNetworkWasUnavailable) {
                    // A QUIC idle timeout commonly means Wi-Fi/cellular disappeared. Do not turn
                    // that local outage into a terminal broker failure: keep the foreground VPN in
                    // CONNECTING and wait until an independent broker front is reachable again.
                    awaitPhysicalNetworkAlive()
                }
                // delay() remains owned by punchMonitorJob, so disconnect or a manual connection
                // cancels pending backoff before another discovery or engine start can occur.
                recoveryDecision.awaitBackoff()
                coroutineContext.ensureActive()
                // A long-lived descriptor can expire or move to another hub. Run the complete
                // discovery + punch-first ladder again so recovery gets fresh signed metadata,
                // repunches on the new network when possible, and uses RelayHub otherwise.
                connect(brokerUrl, country, relayID)
            } finally {
                if (punchMonitorJob === coroutineContext[Job]) punchMonitorJob = null
            }
        }
    }

    /**
     * A WSS socket is bound to one Android physical-network epoch. Native adapter loss,
     * end-to-end tunnel failure, or any physical route/interface/DNS change retires the whole
     * session. Recovery always reruns signed discovery and direct Reality first; it never reuses
     * the consumed ticket or assumes that WSS remains the preferred transport.
     */
    private fun startWssMonitor(relay: RelayDescriptor, ownerJob: Job?) {
        val session = wssSession ?: return
        if (wssMonitorJob !== ownerJob) wssMonitorJob?.cancel()

        val networkChanged = CompletableDeferred<String>()
        physicalNetworkMonitor?.close()
        val networkMonitor = try {
            PhysicalNetworkEpochMonitor(applicationContext) {
                networkChanged.complete("physical network epoch changed")
            }
        } catch (error: Throwable) {
            throw LocalTunnelException("network_monitor", error)
        }
        physicalNetworkMonitor = networkMonitor

        wssMonitorJob = serviceScope.launch {
            val failure = try {
                awaitWssFailure(session, networkChanged)
            } catch (error: CancellationException) {
                return@launch
            } catch (error: LocalTunnelException) {
                if (wssSession === session && activeRelayId == relay.id) {
                    terminateForActiveLocalFailure(relay, error)
                }
                if (wssMonitorJob === coroutineContext[Job]) wssMonitorJob = null
                return@launch
            }
            // Close/callback/network events can race. Only the live, promoted WSS session may
            // change status or begin another connection epoch.
            if (wssSession !== session || activeRelayId != relay.id) return@launch
            if (terminateIfActiveEngineStopped(relay)) {
                if (wssMonitorJob === coroutineContext[Job]) wssMonitorJob = null
                return@launch
            }

            try {
                val reason = failure.reason.take(256)
                OpenRungStatusStore.appendLog(getString(R.string.log_wss_path_lost, reason.take(160)))
                TelemetryManager.record(
                    event = "transport_path_lost",
                    relayId = relay.id,
                    attributes = mapOf(
                        "transport" to ACCESS_TRANSPORT_WSS,
                        "trigger" to failure.trigger,
                        "reason" to reason,
                    ),
                )
                val country = requestedTargetCountry
                val relayID = requestedTargetRelayId
                OpenRungStatusStore.setStatus(
                    ConnectionStatus.CONNECTING,
                    relayLabel = null,
                    lastError = null,
                )
                updateNotification(getString(R.string.status_connecting))
                heartbeatJob?.cancel()
                heartbeatJob = null
                engineMonitorJob?.cancel()
                engineMonitorJob = null
                // Engine first, then epoch callback and native adapter; see cleanupActiveTunnel.
                cleanupActiveTunnel()
                activeRelayId = null
                TelemetryManager.endSession("wss_path_lost")
                coroutineContext.ensureActive()

                // A network transition can publish callbacks before the replacement network is
                // usable. Keep the foreground VPN in CONNECTING until a broker front is reachable
                // outside the TUN, then fetch fresh signed metadata and try direct Reality first.
                if (!physicalNetworkAlive()) awaitPhysicalNetworkAlive()
                coroutineContext.ensureActive()
                connect(brokerUrl, country, relayID)
            } finally {
                if (wssMonitorJob === coroutineContext[Job]) wssMonitorJob = null
                if (physicalNetworkMonitor === networkMonitor) {
                    physicalNetworkMonitor = null
                    networkMonitor.close()
                }
            }
        }
    }

    /** Gives an already-published local engine stop priority over simultaneous path recovery. */
    private suspend fun terminateIfActiveEngineStopped(relay: RelayDescriptor): Boolean {
        val reason = engine?.unexpectedStopReason() ?: return false
        terminateForActiveLocalFailure(
            relay = relay,
            error = LocalTunnelException(
                "active_tunnel_engine",
                EngineStartException(reason, null),
            ),
            userMessage = getString(R.string.error_tunnel_engine_stopped),
            logMessage = getString(R.string.log_tunnel_engine_stopped),
        )
        return true
    }

    private suspend fun awaitWssFailure(
        session: WssSession,
        networkChanged: CompletableDeferred<String>,
    ): WssPathFailure = coroutineScope {
        val nativeFailure = async { session.awaitFailure() }
        val healthFailure = async { awaitTunnelHealthFailure() }
        try {
            select {
                networkChanged.onAwait {
                    WssPathFailure(reason = it, trigger = "network_change")
                }
                nativeFailure.onAwait {
                    WssPathFailure(reason = it, trigger = "native_adapter")
                }
                healthFailure.onAwait {
                    WssPathFailure(reason = it, trigger = "tunnel_health")
                }
            }
        } finally {
            nativeFailure.cancel()
            healthFailure.cancel()
        }
    }

    private suspend fun awaitPunchFailure(session: NatPunchSession): PunchPathFailure = coroutineScope {
        val nativeFailure = async { session.awaitFailure() }
        val healthFailure = async { awaitTunnelHealthFailure() }
        try {
            select {
                nativeFailure.onAwait {
                    PunchPathFailure(reason = it, waitForPhysicalNetwork = true)
                }
                healthFailure.onAwait {
                    // The health loop already proved a broker front is reachable on a physical
                    // Network, so it can re-ladder immediately.
                    PunchPathFailure(reason = it, waitForPhysicalNetwork = false)
                }
            }
        } finally {
            nativeFailure.cancel()
            healthFailure.cancel()
        }
    }

    /**
     * Mirrors the desktop client's thresholded through-tunnel health monitor. Only after repeated
     * VPN failures do we probe the broker fronts on a physical Android [Network]; a local outage is
     * left alone, while a reachable front proves that the direct tunnel itself needs recovery.
     */
    private suspend fun awaitTunnelHealthFailure(): String {
        var failures = 0
        while (true) {
            delay(Random.nextLong(PUNCH_HEALTH_MIN_DELAY_MS, PUNCH_HEALTH_MAX_DELAY_MS + 1))
            try {
                InternetProbe(applicationContext).verifyOnce()
                failures = 0
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                if (!isGenuineRemoteDataPathFailure(error)) {
                    throw LocalTunnelException("active_tunnel_health", error)
                }
                failures++
                if (failures < PUNCH_HEALTH_FAILURE_THRESHOLD) continue
                if (!physicalNetworkAlive()) continue
                return "end-to-end tunnel health probe failed $failures times: " +
                    (error.message ?: error::class.java.simpleName)
            }
        }
    }

    private suspend fun physicalNetworkAlive(): Boolean {
        val connectivity = getSystemService(ConnectivityManager::class.java)
        val physicalNetworks = connectivity.allNetworks.filter { network ->
            connectivity.getNetworkCapabilities(network)?.let { capabilities ->
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                    capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            } == true
        }
        if (physicalNetworks.isEmpty()) return false

        val fronts = AppConfig.brokerCandidates(brokerUrl).urls
        for (network in physicalNetworks) {
            for (front in fronts) {
                if (probePhysicalNetwork(network, front)) return true
            }
        }
        return false
    }

    private suspend fun awaitPhysicalNetworkAlive() {
        while (!physicalNetworkAlive()) {
            delay(PHYSICAL_NETWORK_RETRY_DELAY_MS)
        }
    }

    private suspend fun probePhysicalNetwork(network: Network, front: String): Boolean =
        withContext(Dispatchers.IO) {
            val connection = runCatching {
                network.openConnection(URL(front)) as HttpURLConnection
            }.getOrNull() ?: return@withContext false
            try {
                connection.requestMethod = "HEAD"
                connection.connectTimeout = PHYSICAL_NETWORK_PROBE_TIMEOUT_MS
                connection.readTimeout = PHYSICAL_NETWORK_PROBE_TIMEOUT_MS
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                // Any HTTP response proves the physical path is alive; authentication and body
                // semantics are irrelevant here because this request never supplies identity data.
                connection.responseCode > 0
            } catch (error: CancellationException) {
                throw error
            } catch (_: Throwable) {
                false
            } finally {
                connection.disconnect()
            }
        }

    private fun cleanupActiveTunnel() {
        val activeEngine = engine
        engine = null
        runCatching { activeEngine?.stop() }

        val activeNetworkMonitor = physicalNetworkMonitor
        physicalNetworkMonitor = null
        runCatching { activeNetworkMonitor?.close() }

        val activePunchSession = punchSession
        punchSession = null
        runCatching { activePunchSession?.close() }

        val activeWssSession = wssSession
        wssSession = null
        runCatching { activeWssSession?.close() }
    }

    private fun closePunchSession(session: NatPunchSession) {
        if (punchSession === session) punchSession = null
        session.close()
    }

    private fun closeWssSession(session: WssSession) {
        if (wssSession === session) {
            wssSession = null
            physicalNetworkMonitor?.close()
            physicalNetworkMonitor = null
        }
        session.close()
    }

    private data class PunchPathFailure(
        val reason: String,
        val waitForPhysicalNetwork: Boolean,
    )

    private data class WssPathFailure(
        val reason: String,
        val trigger: String,
    )

    private fun Long.toDisplaySeconds(): Long = (this + 999) / 1_000

    private data class ConnectedRelay(
        val relay: RelayDescriptor,
        val tcpLatencyMs: Long?,
        val tunnelStartMs: Long,
        val internetProbeMs: Long,
        val attempts: Int,
        val accessTransport: String,
        val frontId: String?,
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
        internal const val PUNCH_HEALTH_MIN_DELAY_MS = 25_000L
        internal const val PUNCH_HEALTH_MAX_DELAY_MS = 35_000L
        internal const val PUNCH_HEALTH_FAILURE_THRESHOLD = 3
        private const val PHYSICAL_NETWORK_PROBE_TIMEOUT_MS = 3_000
        private const val PHYSICAL_NETWORK_RETRY_DELAY_MS = 5_000L
        private const val ACCESS_TRANSPORT_DIRECT = "direct"
        private const val ACCESS_TRANSPORT_PUNCH = "punch"
        private const val ACCESS_TRANSPORT_WSS = "wss"

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
