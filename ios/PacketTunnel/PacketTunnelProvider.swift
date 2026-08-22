import Foundation
import NetworkExtension
import OSLog

/// The iOS equivalent of Android's `OpenRungVpnService`: it owns the connection state machine,
/// per-relay reachability/engine/internet-probe flow, geo relay-label resolution, lifecycle
/// telemetry, and the heartbeat loop. Rich state is published to the app via `SharedConnectionState`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// All fields describing the currently owned transport are confined to `lifecycleQueue`.
    /// Keeping them in one tuple makes install, promotion, validation and teardown atomic across
    /// NetworkExtension callbacks and Swift-concurrency tasks.
    private struct ActiveTransportState {
        var engine: (any PacketTunnelProxyEngine)? = nil
        var punchSession: (any PunchNativeSession)? = nil
        var wssSession: (any WssNativeSession)? = nil
        var relayID: String? = nil
        var accessTransport = AccessTransport.direct
        var wssFrontID: String? = nil
        var epoch: UUID? = nil
    }

    private struct ActiveTransportSnapshot {
        let engine: (any PacketTunnelProxyEngine)?
        let relayID: String?
        let wssFrontID: String?
        let epoch: UUID
    }

    private struct DetachedActiveTransport {
        let engine: (any PacketTunnelProxyEngine)?
        let punchSession: (any PunchNativeSession)?
        let wssSession: (any WssNativeSession)?
        let relayID: String?
        let networkMonitor: PhysicalNetworkEpochMonitor?
    }

    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "PacketTunnel")
    private let selector = RelaySelector()
    private let punchFallbackPolicy = PunchFallbackPolicy()
    private let punchRecoveryCircuitBreaker = PunchRecoveryCircuitBreaker()
    private let wssFallbackPolicy = WssFallbackPolicy(validator: NativeWssFrontValidator())
    private var heartbeatTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var engineMonitorTask: Task<Void, Never>?
    private var transportMonitorTask: Task<Void, Never>?
    private var transportRecoveryTask: Task<Void, Never>?
    private var transportMonitorGeneration: UUID?
    private var physicalNetworkMonitor: PhysicalNetworkEpochMonitor?
    private var activeTransport = ActiveTransportState()
    private var brokerURL = AppConfig.defaultBrokerURL
    /// Native-close, NWPath and health callbacks all enter this queue before they may mutate the
    /// provider's recovery state. WssRecoveryGate then lets only one callback claim an epoch.
    private let lifecycleQueue = DispatchQueue(label: "com.openrung.app.tunnel-lifecycle")
    private let wssRecoveryGate = WssRecoveryGate()
    private let punchRecoveryGate = PunchRecoveryGate()
    /// Read and written only on lifecycleQueue. stopTunnel flips this before it captures tasks, so
    /// a callback already queued behind stop cannot create an untracked reconnect/termination task.
    private var lifecycleIsStopping = false
    private var terminalLifecycleTask: Task<Void, Never>?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let task = Task { await connect(completionHandler: completionHandler, isRecovery: false) }
        lifecycleQueue.sync {
            lifecycleIsStopping = false
            // A new provider start is not a continuation of a prior recovery epoch.
            reasserting = false
            punchRecoveryCircuitBreaker.reset()
            connectTask = task
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let pending = lifecycleQueue.sync {
            lifecycleIsStopping = true
            // User stop is terminal, not a tunnel re-establishment attempt.
            reasserting = false
            wssRecoveryGate.clear()
            punchRecoveryGate.clear()
            punchRecoveryCircuitBreaker.reset()
            let pending = PendingTunnelTasks(
                connect: connectTask,
                recovery: transportRecoveryTask,
                terminal: terminalLifecycleTask,
                heartbeat: heartbeatTask,
                engineObserver: engineMonitorTask,
                transportObserver: transportMonitorTask
            )
            connectTask = nil
            transportRecoveryTask = nil
            terminalLifecycleTask = nil
            heartbeatTask = nil
            engineMonitorTask = nil
            transportMonitorTask = nil
            transportMonitorGeneration = nil
            pending.cancelAll()
            return pending
        }
        // Cancel any in-flight connect and wait for it to unwind BEFORE tearing down, so it can't
        // assign a new engine or publish .connected for a tunnel we're stopping. connect() checks
        // for cancellation before it commits; a libbox engine it already started (start() is not
        // cancellable) is stopped below, after the await.
        SharedConnectionState.setStatus(.disconnecting)

        Task {
            // Connection-owning tasks must finish before engine teardown. In particular,
            // EmbeddedProxyEngine.start is not cancellable, so stopping it concurrently with a
            // recovery connect can corrupt libbox lifecycle state.
            await TunnelTransportCleanup.drain(pending.connectionOwners)

            let detached = cleanupActiveTransport(cancelMonitor: false)
            if let relayID = detached?.relayID {
                TelemetryManager.record("tunnel_stopped", relayId: relayID)
            }
            let telemetryURLString = TelemetryManager.endSession(reason: "disconnect")
                ?? AppConfig.telemetryBrokerURL.absoluteString
            // Engine/WSS observer waits are unblocked by the ordered cleanup above.
            await TunnelTransportCleanup.drain(pending.observers)
            SharedConnectionState.setStatus(.disconnected, clearRelayLabel: true, clearError: true)

            try? await TelemetryManager.flush(brokerURL: telemetryURLString)
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // Pause the engine while the device sleeps so iOS doesn't terminate the extension for CPU
        // wakeups; libbox schedules its own auto-wake. Without this the extension can be silently
        // killed while SharedConnectionState still reports .connected.
        lifecycleQueue.sync {
            guard lifecycleIsStopping == false else { return }
            activeTransport.engine?.pause()
        }
        completionHandler()
    }

    override func wake() {
        // Waking the device is not itself a network epoch. Serialize engine wake with teardown;
        // changed NWPath fingerprints, native close, and health probes own WSS recovery.
        lifecycleQueue.sync {
            guard lifecycleIsStopping == false else { return }
            activeTransport.engine?.wake()
        }
    }

    // MARK: - Connection flow

    private func connect(completionHandler: ((Error?) -> Void)?, isRecovery: Bool) async {
        var startCompletionDelivered = false
        let brokerURL = resolveBrokerURL()
        let targetCountry = resolveTargetCountry()
        let targetRelayID = resolveTargetRelayID()
        // One snapshot per connect attempt: every candidate (and its preflight) below uses the
        // same rules; recovery reconnects re-read on their next connect() pass.
        let splitTunnelRules = resolveSplitTunnelRules()
        self.brokerURL = brokerURL
        // Start with the configured telemetry target so the pre-discovery event has a route. Once
        // verified discovery succeeds, this session follows the winning front.
        var telemetryURLString = AppConfig.telemetryBrokerURL.absoluteString
        let session = TelemetryManager.beginSession(brokerURL: telemetryURLString)
        var failureStage = "preparing"

        TelemetryManager.record("connection_attempted")
        SharedConnectionState.setBrokerURL(brokerURL.absoluteString)
        SharedConnectionState.clearError()
        SharedConnectionState.setStatus(.preparing, clearRelayLabel: true, clearError: true)

        do {
            SharedConnectionState.setStatus(.connecting)
            SharedConnectionState.appendLog("fetching relays from \(brokerURL.absoluteString)")
            failureStage = "broker_fetch"

            // Resolve our own geo concurrently with the broker fetch (both before the tunnel is up).
            async let geoLookup: ClientGeoInfo? = try? await GeoIpClient().lookup()
            let brokerStartedNs = DispatchTime.now().uptimeNanoseconds
            // brokerapi owns candidate defaults, strict custom-override handling, staggered racing,
            // verified relay-list selection, and opportunistic ECH with verified ordinary-TLS
            // fallback.
            let fetch = try await BrokerClient.firstReachable(
                primary: brokerURL,
                // Targeted connects (country or exact relay) need the full set so the target is present.
                limit: targetCountry == nil && targetRelayID == nil
                    ? AppConfig.relayLimit
                    : AppConfig.directoryRelayLimit,
                clientID: session.clientId,
                sessionID: session.id
            )
            let response = fetch.response
            let brokerFetchMs = Int64((DispatchTime.now().uptimeNanoseconds - brokerStartedNs) / 1_000_000)
            // Pin the verified winner for every session-scoped broker call, including telemetry.
            if fetch.brokerURL != brokerURL {
                SharedConnectionState.appendLog("configured broker did not win discovery; using fallback \(fetch.brokerURL.absoluteString)")
            }
            try Task.checkCancellation()
            telemetryURLString = fetch.brokerURL.absoluteString
            guard TelemetryManager.updateBrokerURL(
                telemetryURLString,
                forSessionId: session.id
            ) else {
                throw CancellationError()
            }
            self.brokerURL = fetch.brokerURL
            if let geo = await geoLookup {
                TelemetryManager.setGeoInfo(geo)
            }

            let candidates = selector.orderedCandidates(from: response.relays, now: response.serverTime)
            SharedConnectionState.appendLog("broker returned \(response.relays.count) relays; \(candidates.count) usable")
            // Make the attempt visible before relay dialing. Delivery failure is non-fatal and
            // leaves the durable outbox untouched, but cancellation still aborts this stale epoch.
            do {
                try await TelemetryManager.flush(brokerURL: telemetryURLString)
            } catch is CancellationError {
                // Abort only for real task cancellation. The native transport verifies the
                // caller's cancellation state before mapping its own "cancelled" kind, but this
                // mid-connect path keeps its own guard: a CancellationError from a dependency
                // while this task is live must stay a failed best-effort attempt, not silently
                // end the epoch.
                try Task.checkCancellation()
            } catch {
                // Best effort; the success/failure tail retries the retained outbox.
            }
            guard candidates.isEmpty == false else {
                throw PacketTunnelError.noUsableRelay
            }

            let targetedCandidates: [RelayDescriptor]
            if let targetRelayID {
                // A relay picked from the list's expanded per-relay rows: pin that exact relay,
                // never silently fall back to a different one.
                failureStage = "relay_id_filter"
                let matched = candidates.filter { $0.id == targetRelayID }
                guard let picked = matched.first else {
                    throw PacketTunnelError.relayNotAvailable
                }
                let displayName = picked.displayName()
                SharedConnectionState.appendLog("connecting to relay \(displayName)")
                targetedCandidates = matched
            } else if let targetCountry {
                let countryName = CountryGeo.displayName(targetCountry) ?? targetCountry
                SharedConnectionState.appendLog("connecting to a relay in \(countryName)")
                failureStage = "relay_geo_filter"
                targetedCandidates = filterByCountry(candidates, countryCode: targetCountry)
                guard targetedCandidates.isEmpty == false else {
                    throw PacketTunnelError.noRelayInCountry(countryName)
                }
            } else {
                targetedCandidates = candidates
            }

            // Reorder (never shrink) the ladder by this client's measured TCP latency. Broker
            // order already scores load headroom / success rate / latency / speed from the
            // broker's vantage, so RelayRanker only overrides it across latency buckets — within
            // a bucket the broker's load balancing still decides. A pinned relay skips ranking:
            // there is exactly one candidate and the user chose it.
            let rankedCandidates: [RelayRanker.RankedRelay]
            if targetRelayID == nil, targetedCandidates.count > 1 {
                failureStage = "relay_rank"
                let probeCount = min(targetedCandidates.count, RelayRanker.defaultMaxProbes)
                SharedConnectionState.appendLog("measuring TCP latency to \(probeCount) relays")
                rankedCandidates = await RelayRanker.rankByTcpLatency(targetedCandidates)
            } else {
                rankedCandidates = targetedCandidates.map { .init(relay: $0, probeMs: nil) }
            }

            failureStage = "relay_connect"
            let connected = try await connectFirstAvailableRelay(
                rankedCandidates.map(\.relay),
                splitTunnel: splitTunnelRules
            )

            // A stop may have arrived while we were connecting. Don't publish .connected or start
            // the heartbeat for a tunnel that's being torn down; stopTunnel awaited this task and
            // stops the engine connectFirstAvailableRelay assigned.
            try Task.checkCancellation()

            let relay = connected.relay
            let promoted = lifecycleQueue.sync {
                guard
                    lifecycleIsStopping == false,
                    activeTransport.epoch == connected.transportEpoch,
                    activeTransport.engine === connected.engine,
                    connected.punchSession == nil
                        || activeTransport.punchSession === connected.punchSession,
                    connected.wssSession == nil || activeTransport.wssSession === connected.wssSession
                else { return false }
                activeTransport.relayID = relay.id
                activeTransport.accessTransport = connected.accessTransport
                activeTransport.wssFrontID = connected.frontID
                // NetworkExtension exposes the recovered session as Connected only after the new
                // engine/session tuple has atomically replaced the failed transport.
                reasserting = false
                return true
            }
            guard promoted else { throw CancellationError() }
            TelemetryManager.markConnected(relayId: relay.id)
            SharedConnectionState.setStatus(
                .connected,
                relayName: relay.displayName(),
                // Bridge contract: anything but "foundation" collapses to "volunteer".
                relayClass: relay.normalizedNodeClass(),
                clearRelayLabel: true,
                clearError: true
            )
            applyRelayLocation(relay)
            var successMeasurements: [String: Int64] = [
                "broker_fetch_ms": brokerFetchMs,
                "tunnel_start_ms": connected.tunnelStartMs,
                "internet_probe_ms": connected.internetProbeMs,
                "relay_attempts": Int64(connected.attempts),
            ]
            if let tcpLatencyMs = connected.tcpLatencyMs {
                successMeasurements["relay_tcp_ms"] = tcpLatencyMs
            }
            // Rank observability: where the connected relay sat in broker order before ranking,
            // and its probe latency when it was probed — the pair that shows whether client-side
            // ranking actually beats broker order on tunnel_start_ms.
            successMeasurements["relay_broker_index"] =
                Int64(targetedCandidates.firstIndex { $0.id == relay.id } ?? -1)
            if let probeMs = rankedCandidates.first(where: { $0.relay.id == relay.id })?.probeMs {
                successMeasurements["relay_probe_ms"] = probeMs
            }
            TelemetryManager.record(
                "connection_succeeded",
                relayId: relay.id,
                attributes: {
                    var attributes = ["transport": connected.accessTransport]
                    if let frontID = connected.frontID { attributes["front_id"] = frontID }
                    return attributes
                }(),
                measurements: successMeasurements
            )
            try Task.checkCancellation()
            let engineStopped = lifecycleQueue.sync {
                activeTransport.epoch != connected.transportEpoch
                    || activeTransport.engine !== connected.engine
                    || activeTransport.engine?.hasUnexpectedStop == true
            }
            guard engineStopped == false else {
                throw LocalTunnelError(
                    stage: "active_tunnel_engine",
                    underlying: PacketTunnelProxyEngineError.engineStartFailed(
                        "libbox stopped before the success handoff"
                    )
                )
            }

            logger.info("Connected through relay \(relay.id, privacy: .public)")
            completionHandler?(nil)
            startCompletionDelivered = completionHandler != nil

            // Completion is the linearization point. Active callbacks installed afterward may
            // report a later path loss, but can never race an outstanding start completion.
            startHeartbeatLoop()
            startEngineMonitor(relay: relay, transportEpoch: connected.transportEpoch)
            if connected.accessTransport == AccessTransport.punch {
                startPunchMonitor(relay: relay)
            } else if connected.accessTransport == AccessTransport.wss {
                startWssMonitor(relay: relay)
            }

            // Final, best-effort work only: no connection state or completion follows this await.
            guard Task.isCancelled == false else { return }
            do {
                try await TelemetryManager.flush(brokerURL: telemetryURLString)
            } catch is CancellationError {
                return
            } catch {
                // Connection success does not depend on telemetry delivery.
            }
        } catch is CancellationError {
            // Stopped mid-connect. Leave engine teardown and the .disconnected status to stopTunnel
            // (which awaited this task); don't record a failure or publish an error for a
            // user-initiated stop.
            if startCompletionDelivered == false { completionHandler?(CancellationError()) }
        } catch {
            cleanupActiveTransport()
            let message = FailureClassifier.describe(error)
            var attributes = ["failure_stage": failureStage, "error_type": FailureClassifier.errorType(error)]
            // Additive: keep error_type; the broker prefers failure_reason and falls back to it.
            let reason = FailureClassifier.classify(error)
            if reason.isEmpty == false { attributes["failure_reason"] = reason }
            let detail = FailureClassifier.detail(error)
            if detail.isEmpty == false { attributes["failure_detail"] = detail }
            TelemetryManager.record("connection_failed", attributes: attributes)
            let terminalTelemetryURLString = TelemetryManager.endSession(reason: "connection_failed")
                ?? telemetryURLString
            try? await TelemetryManager.flush(brokerURL: terminalTelemetryURLString)
            guard Task.isCancelled == false else {
                completionHandler?(CancellationError())
                return
            }
            SharedConnectionState.fail(message)
            logger.error("Failed to start tunnel: \(message, privacy: .public)")
            if isRecovery {
                lifecycleQueue.sync { reasserting = false }
                cancelTunnelWithError(error)
            } else {
                completionHandler?(error)
            }
        }
    }

    private func connectFirstAvailableRelay(
        _ candidates: [RelayDescriptor],
        splitTunnel: SplitTunnelRules?
    ) async throws -> ConnectedRelay {
        var lastError: Error?

        for (index, relay) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                return try await wssFallbackPolicy.connect(
                    relay: relay,
                    attemptDirect: { [self] in
                        try await attemptDirectCandidate(relay, attempt: index + 1, splitTunnel: splitTunnel)
                    },
                    attemptWss: { [self] front in
                        try await attemptWssCandidate(
                            relay,
                            front: front,
                            attempt: index + 1,
                            splitTunnel: splitTunnel
                        )
                    },
                    onDirectFallback: { [self] failure in
                        cleanupActiveTransport()
                        recordRelayAttemptFailure(relay, error: failure, attempt: index + 1)
                        TelemetryManager.record(
                            "transport_fallback",
                            relayId: relay.id,
                            attributes: [
                                "from_transport": AccessTransport.direct,
                                "to_transport": AccessTransport.wss,
                                "failure_reason": FailureClassifier.classify(failure),
                            ]
                        )
                        SharedConnectionState.appendLog("direct Reality path failed; trying the relay's signed WSS fronts")
                    },
                    onWssFailure: { [self] front, failure in
                        cleanupActiveTransport()
                        recordWssTransportFailure(relay, front: front, error: failure)
                        SharedConnectionState.appendLog("WSS front \(front.id) failed at \(failure.stage)")
                    }
                )
            } catch is CancellationError {
                cleanupActiveTransport()
                throw CancellationError()
            } catch let error as LocalTunnelError {
                // Local configuration, engine, permission and platform failures are common to all
                // relays. They are terminal and never mint another WSS ticket.
                cleanupActiveTransport()
                throw error
            } catch {
                lastError = error
                if relayFailureAlreadyRecorded(error) == false {
                    recordRelayAttemptFailure(relay, error: error, attempt: index + 1)
                }
                SharedConnectionState.appendLog("relay \(relay.id) failed: \(FailureClassifier.describe(error))")
                cleanupActiveTransport()
            }
        }

        // Carry the last error itself (not just its message) so connection_failed classifies on the
        // real root cause instead of this generic wrapper.
        throw PacketTunnelError.allRelaysFailed(lastError)
    }

    private func attemptDirectCandidate(
        _ relay: RelayDescriptor,
        attempt: Int,
        splitTunnel: SplitTunnelRules?
    ) async throws -> ConnectedRelay {
        do {
            try EmbeddedProxyEngine.preflight(
                configuration: SingBoxConfiguration(relay: relay, splitTunnel: splitTunnel)
            )
            // Validate the WSS bridge graph before any remote reachability check can unlock ticket
            // acquisition. Port 1 is only a structurally valid placeholder; the actual loopback
            // port returned by wsscore is validated again when that engine is started. Carries the
            // same split-tunnel rules so preflight validates the real fallback config shape.
            try EmbeddedProxyEngine.preflight(
                configuration: SingBoxConfiguration(
                    relay: relay,
                    bridgeHost: "127.0.0.1",
                    bridgePort: 1,
                    splitTunnel: splitTunnel
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalTunnelError(stage: "engine_preflight", underlying: error)
        }

        SharedConnectionState.appendLog("trying relay \(relay.id) at \(relay.publicHost):\(relay.publicPort)")
        SharedConnectionState.appendLog("checking relay TCP reachability")
        let tcpLatencyMs: Int64
        do {
            tcpLatencyMs = try await RelayReachability.checkTcp(relay)
        } catch is CancellationError {
            throw CancellationError()
        } catch RelayReachabilityError.invalidPort {
            throw LocalTunnelError(stage: "relay_descriptor", underlying: RelayReachabilityError.invalidPort)
        } catch {
            guard isGenuineRemoteDataPathFailure(error) else {
                throw LocalTunnelError(stage: "direct_socket", underlying: error)
            }
            throw DirectPathError(
                stage: "tcp",
                underlying: PacketTunnelError.relayUnreachable(
                    host: relay.publicHost,
                    port: relay.publicPort,
                    underlying: error
                )
            )
        }

        return try await punchFallbackPolicy.connect(
            attemptPunch: { [self] () async throws -> ConnectedRelay? in
                guard let punched = try await attemptDirectPunch(relay) else { return nil }
                return try await startTunnel(
                    relay: relay,
                    configuration: SingBoxConfiguration(
                        relay: relay,
                        bridgeHost: punched.result.bridgeHost,
                        bridgePort: punched.result.bridgePort,
                        splitTunnel: splitTunnel
                    ),
                    tcpLatencyMs: tcpLatencyMs,
                    attempt: attempt,
                    accessTransport: AccessTransport.punch,
                    frontID: nil,
                    expectedPunchSession: punched.session,
                    expectedTransportEpoch: punched.transportEpoch
                )
            },
            attemptRelayHub: { [self] in
                try await startTunnel(
                    relay: relay,
                    configuration: SingBoxConfiguration(relay: relay, splitTunnel: splitTunnel),
                    tcpLatencyMs: tcpLatencyMs,
                    attempt: attempt,
                    accessTransport: AccessTransport.direct,
                    frontID: nil
                )
            },
            onPunchFallback: { [self] failure in
                cleanupActiveTransport()
                var attributes: [String: String] = [:]
                let reason = FailureClassifier.classify(failure)
                if reason.isEmpty == false { attributes["failure_reason"] = reason }
                let detail = FailureClassifier.detail(failure)
                if detail.isEmpty == false { attributes["failure_detail"] = detail }
                TelemetryManager.record(
                    "punch_fallback",
                    relayId: relay.id,
                    attributes: attributes
                )
                SharedConnectionState.appendLog(
                    "direct punched path could not carry tunnel traffic; using RelayHub"
                )
            }
        )
    }

    /// Attempts signaling, UDP hole punching, QUIC authentication, and the loopback bridge. A
    /// returned value owns a live native session installed in `activeTransport`; nil means the
    /// ordinary same-relay hub rung should be attempted.
    private func attemptDirectPunch(_ relay: RelayDescriptor) async throws -> PreparedPunch? {
        guard relay.punchCapable else { return nil }
        let punchAllowed = lifecycleQueue.sync {
            punchRecoveryCircuitBreaker.allowsDirectPunch(relayID: relay.id)
        }
        guard punchAllowed else {
            TelemetryManager.record(
                "punch_skipped",
                relayId: relay.id,
                attributes: ["reason": "recovery_circuit_open"]
            )
            return nil
        }

        TelemetryManager.record("punch_attempted", relayId: relay.id)
        SharedConnectionState.appendLog("attempting direct NAT punch")
        let session: any PunchNativeSession
        do {
            guard let created = try NativePunchSessionFactory.make(relay: relay) else {
                recordPunchFailure(
                    relay,
                    reason: "endpoint",
                    natClass: "",
                    detail: ""
                )
                SharedConnectionState.appendLog("NAT punch unavailable (endpoint)")
                return nil
            }
            session = created
        } catch {
            recordPunchFailure(
                relay,
                reason: "client",
                natClass: "",
                detail: FailureClassifier.describe(error)
            )
            SharedConnectionState.appendLog("NAT punch unavailable (client)")
            return nil
        }

        let transportEpoch = UUID()
        let installed = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                activeTransport.engine == nil,
                activeTransport.punchSession == nil,
                activeTransport.wssSession == nil
            else { return false }
            activeTransport.punchSession = session
            activeTransport.relayID = nil
            activeTransport.accessTransport = AccessTransport.direct
            activeTransport.wssFrontID = nil
            activeTransport.epoch = transportEpoch
            return true
        }
        guard installed else {
            session.close()
            throw CancellationError()
        }

        let result: PunchNativeConnectResult
        do {
            result = try await session.establish()
            try Task.checkCancellation()
        } catch is CancellationError {
            closePunchSession(session)
            throw CancellationError()
        } catch {
            closePunchSession(session)
            if case let PunchNativeClientError.establishmentFailed(
                failureReason,
                detail,
                natClass
            ) = error {
                recordPunchFailure(
                    relay,
                    reason: failureReason.rawValue,
                    natClass: natClass,
                    detail: detail
                )
                SharedConnectionState.appendLog(
                    "NAT punch failed (\(failureReason.rawValue))"
                )
            } else {
                recordPunchFailure(
                    relay,
                    reason: "client",
                    natClass: "",
                    detail: FailureClassifier.describe(error)
                )
                SharedConnectionState.appendLog("NAT punch failed (client)")
            }
            return nil
        }

        var attributes: [String: String] = [:]
        if result.natClass.isEmpty == false { attributes["nat_class"] = result.natClass }
        TelemetryManager.record(
            "punch_succeeded",
            relayId: relay.id,
            attributes: attributes,
            measurements: ["punch_rtt_ms": result.rttMillis]
        )
        let natClass = result.natClass.isEmpty ? "unknown NAT" : result.natClass
        SharedConnectionState.appendLog("direct NAT punch succeeded (\(natClass))")
        return PreparedPunch(
            session: session,
            result: result,
            transportEpoch: transportEpoch
        )
    }

    private func recordPunchFailure(
        _ relay: RelayDescriptor,
        reason: String,
        natClass: String,
        detail: String
    ) {
        var attributes = ["reason": reason]
        if natClass.isEmpty == false { attributes["nat_class"] = String(natClass.prefix(64)) }
        if detail.isEmpty == false {
            attributes["failure_detail"] = FailureClassifier.truncate(detail)
        }
        TelemetryManager.record("punch_failed", relayId: relay.id, attributes: attributes)
    }

    private func attemptWssCandidate(
        _ relay: RelayDescriptor,
        front: WssFrontDescriptor,
        attempt: Int,
        splitTunnel: SplitTunnelRules?
    ) async throws -> ConnectedRelay {
        let telemetrySession = TelemetryManager.activeSession()
        let ticket: WssSessionTicket
        do {
            ticket = try await WssTicketClient().requestWithFailover(
                brokerURLs: wssTicketBrokerFronts(),
                relayID: relay.id,
                frontID: front.id,
                clientID: telemetrySession?.clientId,
                sessionID: telemetrySession?.id
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as BrokerNativeFailure where failure.isLocalPlatformFailure {
            throw LocalTunnelError(stage: "wss_ticket", underlying: failure)
        } catch {
            throw WssTransportError(stage: "ticket", frontID: front.id, underlying: error)
        }
        guard ticket.url == front.url else {
            throw WssTransportError(
                stage: "ticket_binding",
                frontID: front.id,
                underlying: URLError(.cannotParseResponse)
            )
        }
        guard ticket.isFresh(at: Date()) else {
            throw WssTransportError(
                stage: "ticket_expired",
                frontID: front.id,
                underlying: URLError(.userAuthenticationRequired)
            )
        }

        let session: any WssNativeSession
        do {
            session = try NativeWssSessionFactory.make(frontURL: front.url, ticket: ticket.ticket)
        } catch {
            throw LocalTunnelError(stage: "wss_client", underlying: error)
        }
        let transportEpoch = UUID()
        let installed = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                activeTransport.engine == nil,
                activeTransport.punchSession == nil,
                activeTransport.wssSession == nil
            else { return false }
            activeTransport.wssSession = session
            activeTransport.relayID = nil
            activeTransport.accessTransport = AccessTransport.direct
            activeTransport.wssFrontID = nil
            activeTransport.epoch = transportEpoch
            return true
        }
        guard installed else {
            session.close()
            throw CancellationError()
        }
        let endpoint: WssNativeConnectResult
        do {
            endpoint = try await session.connect()
        } catch is CancellationError {
            closeWssSession(session)
            throw CancellationError()
        } catch {
            closeWssSession(session)
            if let nativeError = error as? WssNativeClientError, nativeError.isLocalFailure {
                throw LocalTunnelError(stage: "wss_client", underlying: nativeError)
            }
            throw WssTransportError(stage: "wss_handshake", frontID: front.id, underlying: error)
        }
        try Task.checkCancellation()
        SharedConnectionState.appendLog("WSS front \(front.id) connected; starting end-to-end Reality")

        return try await startTunnel(
            relay: relay,
            configuration: SingBoxConfiguration(
                relay: relay,
                bridgeHost: endpoint.bridgeHost,
                bridgePort: endpoint.bridgePort,
                splitTunnel: splitTunnel
            ),
            tcpLatencyMs: nil,
            attempt: attempt,
            accessTransport: AccessTransport.wss,
            frontID: front.id,
            expectedWssSession: session,
            expectedTransportEpoch: transportEpoch
        )
    }

    private func startTunnel(
        relay: RelayDescriptor,
        configuration: SingBoxConfiguration,
        tcpLatencyMs: Int64?,
        attempt: Int,
        accessTransport: String,
        frontID: String?,
        expectedPunchSession: (any PunchNativeSession)? = nil,
        expectedWssSession: (any WssNativeSession)? = nil,
        expectedTransportEpoch: UUID? = nil
    ) async throws -> ConnectedRelay {
        let proxyEngine = EmbeddedProxyEngine()
        let transportEpoch: UUID? = lifecycleQueue.sync {
            guard lifecycleIsStopping == false, activeTransport.engine == nil else { return nil }
            if let expectedTransportEpoch {
                guard
                    activeTransport.epoch == expectedTransportEpoch,
                    (
                        expectedPunchSession != nil
                            && activeTransport.punchSession === expectedPunchSession
                            && activeTransport.wssSession == nil
                    ) || (
                        expectedWssSession != nil
                            && activeTransport.wssSession === expectedWssSession
                            && activeTransport.punchSession == nil
                    )
                else { return nil }
                activeTransport.engine = proxyEngine
                return expectedTransportEpoch
            }
            guard
                activeTransport.punchSession == nil,
                activeTransport.wssSession == nil
            else { return nil }
            let epoch = UUID()
            activeTransport.engine = proxyEngine
            activeTransport.relayID = nil
            activeTransport.accessTransport = AccessTransport.direct
            activeTransport.wssFrontID = nil
            activeTransport.epoch = epoch
            return epoch
        }
        guard let transportEpoch else { throw CancellationError() }
        let tunnelStartedNs = DispatchTime.now().uptimeNanoseconds
        do {
            try await proxyEngine.start(relay: relay, configuration: configuration, tunnelProvider: self)
            try Task.checkCancellation()
        } catch is CancellationError {
            proxyEngine.stop()
            removeEngineIfCurrent(proxyEngine, transportEpoch: transportEpoch)
            throw CancellationError()
        } catch {
            proxyEngine.stop()
            removeEngineIfCurrent(proxyEngine, transportEpoch: transportEpoch)
            throw LocalTunnelError(stage: "engine_start", underlying: error)
        }
        let tunnelStartMs = Int64((DispatchTime.now().uptimeNanoseconds - tunnelStartedNs) / 1_000_000)

        SharedConnectionState.appendLog("verifying internet access through the VPN")
        let pathProbe: PacketTunnelPathProbe
        do {
            pathProbe = PacketTunnelPathProbe(
                dnsProbe: PacketTunnelDnsProbe(tunnelProvider: self),
                httpProbe: try PacketTunnelInternetProbe(tunnelProvider: self)
            )
        } catch {
            throw LocalTunnelError(stage: "internet_probe_setup", underlying: error)
        }
        let probe = try await verifyStartupTunnelPath(
            probe: { try await pathProbe.verify() },
            waitForUnexpectedStop: { await proxyEngine.waitForUnexpectedStop() },
            hasUnexpectedStop: { proxyEngine.hasUnexpectedStop },
            prepareForExpectedStop: { proxyEngine.prepareForExpectedStop() },
            wssFrontID: accessTransport == AccessTransport.wss ? frontID : nil
        )
        SharedConnectionState.appendLog("internet access verified in \(probe.durationMs) ms")

        return ConnectedRelay(
            relay: relay,
            tcpLatencyMs: tcpLatencyMs,
            tunnelStartMs: tunnelStartMs,
            internetProbeMs: probe.durationMs,
            attempts: attempt,
            accessTransport: accessTransport,
            frontID: frontID,
            engine: proxyEngine,
            punchSession: expectedPunchSession,
            wssSession: expectedWssSession,
            transportEpoch: transportEpoch
        )
    }

    private func removeEngineIfCurrent(
        _ expected: any PacketTunnelProxyEngine,
        transportEpoch: UUID
    ) {
        lifecycleQueue.sync {
            guard
                activeTransport.epoch == transportEpoch,
                activeTransport.engine === expected
            else { return }
            activeTransport.engine = nil
            if activeTransport.punchSession == nil, activeTransport.wssSession == nil {
                activeTransport.epoch = nil
            }
        }
    }

    private func recordRelayAttemptFailure(_ relay: RelayDescriptor, error: Error, attempt: Int) {
        var attributes = ["error_type": FailureClassifier.errorType(error)]
        let reason = FailureClassifier.classify(error)
        if reason.isEmpty == false { attributes["failure_reason"] = reason }
        let detail = FailureClassifier.detail(error)
        if detail.isEmpty == false { attributes["failure_detail"] = detail }
        TelemetryManager.record(
            "relay_attempt_failed",
            relayId: relay.id,
            attributes: attributes,
            measurements: ["attempt": Int64(attempt)]
        )
    }

    private func recordWssTransportFailure(
        _ relay: RelayDescriptor,
        front: WssFrontDescriptor,
        error: WssTransportError
    ) {
        var attributes = [
            "transport": AccessTransport.wss,
            "failure_stage": error.stage,
            "front_id": front.id,
        ]
        let reason = FailureClassifier.classify(error)
        if reason.isEmpty == false { attributes["failure_reason"] = reason }
        TelemetryManager.record("transport_failed", relayId: relay.id, attributes: attributes)
    }

    private func wssTicketBrokerFronts() -> [URL] {
        var result: [URL] = []
        for url in [brokerURL] + AppConfig.defaultBrokerURLs where result.contains(url) == false {
            result.append(url)
        }
        return result
    }

    // MARK: - Active engine / native transport lifecycle and network epochs

    /// Unexpected libbox exit is a local terminal failure under every access transport. In
    /// particular, it must beat a near-simultaneous adapter-close callback.
    private func startEngineMonitor(relay: RelayDescriptor, transportEpoch: UUID) {
        lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                activeTransport.epoch == transportEpoch,
                let monitoredEngine = activeTransport.engine
            else { return }
            engineMonitorTask?.cancel()
            engineMonitorTask = Task { [weak self] in
                guard let reason = await monitoredEngine.waitForUnexpectedStop() else { return }
                guard Task.isCancelled == false else { return }
                self?.requestEngineTermination(
                    relay: relay,
                    expectedEngine: monitoredEngine,
                    transportEpoch: transportEpoch,
                    reason: reason
                )
            }
        }
    }

    private func requestEngineTermination(
        relay: RelayDescriptor,
        expectedEngine: any PacketTunnelProxyEngine,
        transportEpoch: UUID,
        reason: String
    ) {
        lifecycleQueue.async { [weak self] in
            guard
                let self,
                self.lifecycleIsStopping == false,
                self.activeTransport.epoch == transportEpoch,
                self.activeTransport.engine === expectedEngine,
                self.activeTransport.relayID == relay.id
            else { return }
            self.wssRecoveryGate.clear()
            self.punchRecoveryGate.clear()
            self.reasserting = false
            self.transportMonitorTask?.cancel()
            self.transportMonitorTask = nil
            self.transportMonitorGeneration = nil
            let pendingInitialConnect = self.connectTask
            pendingInitialConnect?.cancel()
            self.connectTask = nil
            let pendingRecovery = self.transportRecoveryTask
            pendingRecovery?.cancel()
            self.transportRecoveryTask = nil
            let pendingTerminal = self.terminalLifecycleTask
            pendingTerminal?.cancel()
            self.terminalLifecycleTask = Task { [weak self] in
                // If recovery was already inside noncancellable engine.start, let it unwind before
                // the local terminal path tears down libbox. A previous terminal owner may already
                // have detached this epoch, so let it finish before attempting the same transition.
                await pendingInitialConnect?.value
                await pendingRecovery?.value
                await pendingTerminal?.value
                await self?.terminateForActiveLocalFailure(
                    LocalTunnelError(
                        stage: "active_tunnel_engine",
                        underlying: PacketTunnelProxyEngineError.engineStartFailed(reason)
                    ),
                    relayID: relay.id,
                    expectedEngine: expectedEngine,
                    expectedTransportEpoch: transportEpoch,
                    enforceExpectedState: false
                )
            }
        }
    }

    /// A punched QUIC mapping belongs to one physical-network epoch. Native adapter loss, a path
    /// fingerprint change, or sustained end-to-end probe failure retires the entire engine/bridge
    /// tuple and reruns signed discovery.
    private func startPunchMonitor(relay: RelayDescriptor) {
        let replacedMonitor: PhysicalNetworkEpochMonitor? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                let session = activeTransport.punchSession,
                activeTransport.accessTransport == AccessTransport.punch
            else { return nil }
            transportMonitorTask?.cancel()
            punchRecoveryGate.arm(session)
            punchRecoveryCircuitBreaker.markDirectConnected(
                relayID: relay.id,
                nowElapsedMilliseconds: monotonicMilliseconds()
            )

            let monitor = PhysicalNetworkEpochMonitor { [weak self] _ in
                self?.requestPunchRecovery(
                    trigger: "network_change",
                    expectedSession: session,
                    reason: "physical network epoch changed",
                    countTowardBreaker: false
                )
            }
            let replacedMonitor = physicalNetworkMonitor
            physicalNetworkMonitor = monitor
            transportMonitorTask = Task { [weak self] in
                guard
                    let self,
                    let event = await self.awaitPunchMonitorEvent(
                        session: session,
                        monitor: monitor
                    )
                else { return }
                guard Task.isCancelled == false else { return }
                switch event {
                case .pathFailure(let reason, let trigger, let countTowardBreaker):
                    self.requestPunchRecovery(
                        trigger: trigger,
                        expectedSession: session,
                        reason: reason,
                        countTowardBreaker: countTowardBreaker
                    )
                case .localFailure(let error):
                    self.requestActivePunchLocalFailure(
                        error,
                        relay: relay,
                        expectedSession: session
                    )
                }
            }
            return replacedMonitor
        }
        replacedMonitor?.close()
    }

    private func awaitPunchMonitorEvent(
        session: any PunchNativeSession,
        monitor: PhysicalNetworkEpochMonitor
    ) async -> PunchMonitorEvent? {
        await withTaskGroup(of: PunchMonitorEvent?.self) { group in
            group.addTask {
                let reason = await session.waitForUnexpectedClose()
                guard Task.isCancelled == false else { return nil }
                return .pathFailure(
                    reason: reason,
                    trigger: "native_adapter",
                    countTowardBreaker: monitor.shouldCountNativeAdapterLoss
                )
            }
            group.addTask {
                do {
                    let reason = try await self.awaitTunnelHealthFailure(monitor: monitor)
                    return .pathFailure(
                        reason: reason,
                        trigger: "tunnel_health",
                        countTowardBreaker: true
                    )
                } catch is CancellationError {
                    return nil
                } catch let error as LocalTunnelError {
                    return .localFailure(error)
                } catch {
                    return .localFailure(
                        LocalTunnelError(stage: "active_tunnel_health", underlying: error)
                    )
                }
            }
            while let event = await group.next() {
                if let event {
                    group.cancelAll()
                    return event
                }
            }
            return nil
        }
    }

    private func requestPunchRecovery(
        trigger: String,
        expectedSession: any PunchNativeSession,
        reason: String,
        countTowardBreaker: Bool
    ) {
        let pathLostAtMilliseconds = monotonicMilliseconds()
        lifecycleQueue.async { [weak self] in
            self?.schedulePunchRecoveryOnLifecycleQueue(
                trigger: trigger,
                expectedSession: expectedSession,
                reason: reason,
                countTowardBreaker: countTowardBreaker,
                pathLostAtMilliseconds: pathLostAtMilliseconds
            )
        }
    }

    private func schedulePunchRecoveryOnLifecycleQueue(
        trigger: String,
        expectedSession: any PunchNativeSession,
        reason: String,
        countTowardBreaker: Bool,
        pathLostAtMilliseconds: UInt64
    ) {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        guard lifecycleIsStopping == false else { return }
        guard
            let current = activeTransport.punchSession,
            current === expectedSession,
            activeTransport.accessTransport == AccessTransport.punch
        else { return }
        guard activeTransport.engine?.hasUnexpectedStop != true else { return }
        guard punchRecoveryGate.claim(expectedSession) else { return }

        reasserting = true
        transportMonitorTask?.cancel()
        transportMonitorTask = nil
        let generation = UUID()
        transportMonitorGeneration = generation
        let pendingInitialConnect = connectTask
        pendingInitialConnect?.cancel()
        connectTask = nil
        transportRecoveryTask?.cancel()
        transportRecoveryTask = Task { [weak self] in
            await pendingInitialConnect?.value
            await self?.recoverPunchPath(
                trigger: trigger,
                reason: reason,
                countTowardBreaker: countTowardBreaker,
                pathLostAtMilliseconds: pathLostAtMilliseconds,
                expectedSession: expectedSession,
                generation: generation
            )
        }
    }

    private func requestActivePunchLocalFailure(
        _ error: LocalTunnelError,
        relay: RelayDescriptor,
        expectedSession: any PunchNativeSession
    ) {
        lifecycleQueue.async { [weak self] in
            guard
                let self,
                self.lifecycleIsStopping == false,
                let current = self.activeTransport.punchSession,
                current === expectedSession,
                self.activeTransport.relayID == relay.id
            else { return }
            guard self.punchRecoveryGate.claim(expectedSession) else { return }
            self.reasserting = false
            self.transportMonitorTask?.cancel()
            self.transportMonitorTask = nil
            self.transportMonitorGeneration = nil
            let pendingInitialConnect = self.connectTask
            pendingInitialConnect?.cancel()
            self.connectTask = nil
            let expectedEngine = self.activeTransport.engine
            let expectedTransportEpoch = self.activeTransport.epoch
            let pendingTerminal = self.terminalLifecycleTask
            pendingTerminal?.cancel()
            self.terminalLifecycleTask = Task { [weak self] in
                await pendingInitialConnect?.value
                await pendingTerminal?.value
                await self?.terminateForActiveLocalFailure(
                    error,
                    relayID: relay.id,
                    expectedEngine: expectedEngine,
                    expectedTransportEpoch: expectedTransportEpoch
                )
            }
        }
    }

    private func recoverPunchPath(
        trigger: String,
        reason: String,
        countTowardBreaker: Bool,
        pathLostAtMilliseconds: UInt64,
        expectedSession: any PunchNativeSession,
        generation: UUID
    ) async {
        let snapshot: ActiveTransportSnapshot? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                transportMonitorGeneration == generation,
                let current = activeTransport.punchSession,
                current === expectedSession,
                activeTransport.accessTransport == AccessTransport.punch,
                let epoch = activeTransport.epoch
            else { return nil }
            return ActiveTransportSnapshot(
                engine: activeTransport.engine,
                relayID: activeTransport.relayID,
                wssFrontID: nil,
                epoch: epoch
            )
        }
        guard Task.isCancelled == false, let snapshot else { return }
        defer { finishTransportRecovery(generation: generation) }
        guard Task.isCancelled == false, snapshot.engine?.hasUnexpectedStop != true else { return }

        guard let relayID = snapshot.relayID else { return }
        let boundedReason = String(reason.prefix(256))
        TelemetryManager.record(
            "punch_path_lost",
            relayId: relayID,
            attributes: [
                "trigger": trigger,
                "reason": boundedReason,
            ]
        )
        SharedConnectionState.appendLog("direct punched path ended; reconnecting")
        SharedConnectionState.setStatus(.connecting, clearRelayLabel: true, clearError: true)
        stopHeartbeatLoop()

        // Reality must release the loopback TCP stream before the QUIC adapter is closed.
        guard cleanupActiveTransport(
            cancelMonitor: false,
            expectedTransportEpoch: snapshot.epoch,
            abortIfUnexpectedEngineStopWon: true
        ) != nil else { return }
        let recoveryDecision = lifecycleQueue.sync {
            punchRecoveryCircuitBreaker.onDirectPathLost(
                relayID: relayID,
                nowElapsedMilliseconds: pathLostAtMilliseconds,
                countTowardBreaker: countTowardBreaker
            )
        }
        if case .useRelayHub = recoveryDecision {
            SharedConnectionState.appendLog(
                "direct path is unstable; using RelayHub for this connection"
            )
            TelemetryManager.record(
                "punch_fallback",
                relayId: relayID,
                attributes: [
                    "failure_reason": "unstable_direct_path",
                    "failure_detail": boundedReason,
                ],
                measurements: [
                    "rapid_failure_count": Int64(recoveryDecision.rapidFailureCount),
                    "direct_uptime_ms": telemetryInt64(
                        recoveryDecision.directUptimeMilliseconds
                    ),
                    "recovery_delay_ms": telemetryInt64(
                        recoveryDecision.delayMilliseconds
                    ),
                ]
            )
        } else if recoveryDecision.delayMilliseconds > 0 {
            SharedConnectionState.appendLog(
                "retrying direct path after recovery backoff"
            )
        }
        TelemetryManager.endSession(reason: "punch_path_lost")

        do {
            try await PhysicalNetworkAvailability.waitUntilSatisfied()
            try await recoveryDecision.awaitBackoff()
            try Task.checkCancellation()
            await connect(completionHandler: nil, isRecovery: true)
        } catch is CancellationError {
            return
        } catch {
            lifecycleQueue.sync { reasserting = false }
            cancelTunnelWithError(error)
        }
    }

    private func startWssMonitor(relay: RelayDescriptor) {
        let replacedMonitor: PhysicalNetworkEpochMonitor? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                let session = activeTransport.wssSession,
                activeTransport.accessTransport == AccessTransport.wss
            else { return nil }
            transportMonitorTask?.cancel()
            wssRecoveryGate.arm(session)

            let monitor = PhysicalNetworkEpochMonitor { [weak self] _ in
                self?.requestWssRecovery(
                    trigger: "network_change",
                    expectedSession: session,
                    reason: "physical network epoch changed"
                )
            }
            let replacedMonitor = physicalNetworkMonitor
            physicalNetworkMonitor = monitor
            transportMonitorTask = Task { [weak self] in
                guard let event = await self?.awaitWssMonitorEvent(session: session, monitor: monitor) else {
                    return
                }
                guard Task.isCancelled == false else { return }
                switch event {
                case .pathFailure(let reason, let trigger, let graceful):
                    self?.requestWssRecovery(
                        trigger: trigger,
                        expectedSession: session,
                        reason: reason,
                        graceful: graceful
                    )
                case .localFailure(let error):
                    self?.requestActiveWssLocalFailure(error, relay: relay, expectedSession: session)
                }
            }
            return replacedMonitor
        }
        replacedMonitor?.close()
    }

    private func awaitWssMonitorEvent(
        session: any WssNativeSession,
        monitor: PhysicalNetworkEpochMonitor
    ) async -> TransportMonitorEvent? {
        await withTaskGroup(of: TransportMonitorEvent?.self) { group in
            group.addTask {
                let end = await session.waitForClose()
                guard Task.isCancelled == false else { return nil }
                return .pathFailure(reason: end.reason, trigger: "native_adapter", graceful: end.graceful)
            }
            group.addTask {
                do {
                    let reason = try await self.awaitTunnelHealthFailure(monitor: monitor)
                    return .pathFailure(reason: reason, trigger: "tunnel_health", graceful: false)
                } catch is CancellationError {
                    return nil
                } catch let error as LocalTunnelError {
                    return .localFailure(error)
                } catch {
                    return .localFailure(LocalTunnelError(stage: "active_tunnel_health", underlying: error))
                }
            }
            while let event = await group.next() {
                if let event {
                    group.cancelAll()
                    return event
                }
            }
            return nil
        }
    }

    /// Three consecutive through-tunnel failures are required. A failed/transitioning NWPath keeps
    /// the WSS session in place; once the physical path is satisfied, a threshold breach proves the
    /// established WSS/Reality data path is blackholed and triggers transport-only recovery.
    private func awaitTunnelHealthFailure(
        monitor: PhysicalNetworkEpochMonitor
    ) async throws -> String {
        let probe: PacketTunnelPathProbe
        do {
            probe = PacketTunnelPathProbe(
                dnsProbe: PacketTunnelDnsProbe(tunnelProvider: self),
                httpProbe: try PacketTunnelInternetProbe(tunnelProvider: self)
            )
        } catch {
            throw LocalTunnelError(stage: "active_tunnel_health_setup", underlying: error)
        }
        // The loop ticks at the base cadence forever — a tick reads in-memory counters and costs
        // no radio. Only PROBES open a through-tunnel TLS connection, so only probes are
        // rationed:
        //
        //  - Downlink growth since the last tick is treated as end-to-end health and skips the
        //    probe — but ONLY while nothing is suspected. A counter push can lag by up to the
        //    engine's status interval, so a sample may still carry pre-failure bytes, and a
        //    failed probe's own transmission grows the uplink counter; neither may ever clear
        //    suspicion, so once a probe has failed only a successful probe resets the count.
        //  - Uplink growth WITHOUT downlink growth means something is sending and nothing is
        //    coming back — the signature of a blackholed path with a user on it. That forces a
        //    probe immediately, regardless of accumulated backoff.
        //  - Otherwise the tunnel is idle: probe only when the backed-off allowance (base,
        //    doubling per healthy observation up to the cap) runs out.
        //
        // Detection-latency bound (from actual failure, active user): counter pushes lag by up
        // to the engine status interval, so up to TWO ticks can still read pre-failure downlink
        // and be masked; the next tick's send-without-reply forces the first failed probe, and
        // the remaining threshold probes run at base cadence — ≈ 6×base plus probe timeouts,
        // ~3.5 min worst case (typically far less), versus ~105 s before backoff existed. A
        // fully idle dead tunnel may sit until the cap (~5 min), but with no traffic no one is
        // affected, and the first use flips it onto the fast path above.
        var threshold = TunnelHealthFailureThreshold(requiredFailures: 3)
        var probeAllowanceMs: UInt64 = Self.tunnelHealthBaseIntervalMs
        var msUntilProbe: Int64 = 0
        var lastCounters = TelemetryManager.currentTrafficCounters()
        while true {
            let passMs = UInt64.random(
                in: (Self.tunnelHealthBaseIntervalMs * 5 / 6)...(Self.tunnelHealthBaseIntervalMs * 7 / 6)
            )
            try await Task.sleep(nanoseconds: passMs * 1_000_000)
            let counters = TelemetryManager.currentTrafficCounters()
            let downlinkGrew: Bool
            let uplinkGrew: Bool
            if let counters, let last = lastCounters {
                downlinkGrew = counters.bytesReceived > last.bytesReceived
                uplinkGrew = counters.bytesSent > last.bytesSent
            } else {
                downlinkGrew = false
                uplinkGrew = false
            }
            if let counters { lastCounters = counters }
            if threshold.consecutiveFailures == 0, downlinkGrew {
                probeAllowanceMs = min(probeAllowanceMs * 2, Self.tunnelHealthMaxIntervalMs)
                msUntilProbe = Int64(probeAllowanceMs)
                continue
            }
            msUntilProbe -= Int64(passMs)
            let sendWithoutReply = uplinkGrew && !downlinkGrew
            if threshold.consecutiveFailures == 0, !sendWithoutReply, msUntilProbe > 0 { continue }
            do {
                _ = try await probe.verifyOnce()
                threshold.recordSuccess()
                probeAllowanceMs = min(probeAllowanceMs * 2, Self.tunnelHealthMaxIntervalMs)
                msUntilProbe = Int64(probeAllowanceMs)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isGenuineRemoteDataPathFailure(error) else {
                    throw LocalTunnelError(stage: "active_tunnel_health", underlying: error)
                }
                probeAllowanceMs = Self.tunnelHealthBaseIntervalMs
                msUntilProbe = 0
                guard threshold.recordRemoteFailure(), monitor.isSatisfied else { continue }
                return "end-to-end tunnel health probe failed \(threshold.consecutiveFailures) times"
            }
        }
    }

    private static let tunnelHealthBaseIntervalMs: UInt64 = 30_000
    private static let tunnelHealthMaxIntervalMs: UInt64 = 300_000

    private func requestWssRecovery(
        trigger: String,
        expectedSession: any WssNativeSession,
        reason: String = "WSS transport epoch ended",
        graceful: Bool = false
    ) {
        lifecycleQueue.async { [weak self] in
            self?.scheduleWssRecoveryOnLifecycleQueue(
                trigger: trigger,
                expectedSession: expectedSession,
                reason: reason,
                graceful: graceful
            )
        }
    }

    private func scheduleWssRecoveryOnLifecycleQueue(
        trigger: String,
        expectedSession: any WssNativeSession,
        reason: String,
        graceful: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(lifecycleQueue))
        guard lifecycleIsStopping == false else { return }
        guard
            let current = activeTransport.wssSession,
            current === expectedSession,
            activeTransport.accessTransport == AccessTransport.wss
        else { return }
        // A genuine engine stop is local and terminal even if the WSS adapter reports closure at
        // nearly the same time. Check it before claiming the one-shot recovery gate so the engine
        // monitor retains terminal ownership even when both callbacks arrive together.
        guard activeTransport.engine?.hasUnexpectedStop != true else { return }
        guard wssRecoveryGate.claim(expectedSession) else { return }

        // The current system VPN session remains alive while its transport is rebuilt. This is
        // exactly NETunnelProvider.reasserting: iOS reports Reasserting until promotion commits a
        // replacement tuple, rather than showing a misleading Connected state while traffic is
        // temporarily unavailable.
        reasserting = true
        transportMonitorTask?.cancel()
        transportMonitorTask = nil
        let generation = UUID()
        transportMonitorGeneration = generation
        let pendingInitialConnect = connectTask
        pendingInitialConnect?.cancel()
        connectTask = nil
        transportRecoveryTask?.cancel()
        transportRecoveryTask = Task { [weak self] in
            await pendingInitialConnect?.value
            await self?.recoverWssPath(
                trigger: trigger,
                reason: reason,
                graceful: graceful,
                expectedSession: expectedSession,
                generation: generation
            )
        }
    }

    private func requestActiveWssLocalFailure(
        _ error: LocalTunnelError,
        relay: RelayDescriptor,
        expectedSession: any WssNativeSession
    ) {
        lifecycleQueue.async { [weak self] in
            guard
                let self,
                self.lifecycleIsStopping == false
            else { return }
            guard
                let current = self.activeTransport.wssSession,
                current === expectedSession,
                self.activeTransport.relayID == relay.id
            else { return }
            guard self.wssRecoveryGate.claim(expectedSession) else { return }
            self.reasserting = false
            self.transportMonitorTask?.cancel()
            self.transportMonitorTask = nil
            self.transportMonitorGeneration = nil
            let pendingInitialConnect = self.connectTask
            pendingInitialConnect?.cancel()
            self.connectTask = nil
            let expectedEngine = self.activeTransport.engine
            let expectedTransportEpoch = self.activeTransport.epoch
            let pendingTerminal = self.terminalLifecycleTask
            pendingTerminal?.cancel()
            self.terminalLifecycleTask = Task { [weak self] in
                await pendingInitialConnect?.value
                await pendingTerminal?.value
                await self?.terminateForActiveLocalFailure(
                    error,
                    relayID: relay.id,
                    expectedEngine: expectedEngine,
                    expectedTransportEpoch: expectedTransportEpoch
                )
            }
        }
    }

    private func recoverWssPath(
        trigger: String,
        reason: String,
        graceful: Bool,
        expectedSession: any WssNativeSession,
        generation: UUID
    ) async {
        let snapshot: ActiveTransportSnapshot? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                transportMonitorGeneration == generation,
                let current = activeTransport.wssSession,
                current === expectedSession,
                activeTransport.accessTransport == AccessTransport.wss,
                let epoch = activeTransport.epoch
            else { return nil }
            return ActiveTransportSnapshot(
                engine: activeTransport.engine,
                relayID: activeTransport.relayID,
                wssFrontID: activeTransport.wssFrontID,
                epoch: epoch
            )
        }
        guard Task.isCancelled == false, let snapshot else { return }
        defer { finishTransportRecovery(generation: generation) }

        let relayID = snapshot.relayID
        let frontID = snapshot.wssFrontID
        var attributes = [
            "transport": AccessTransport.wss,
            "trigger": trigger,
        ]
        if let frontID { attributes["front_id"] = frontID }
        // A queued local engine-termination path has precedence. Returning here preserves the
        // active state for that owner; if it wins immediately after this check, it awaits this task
        // and then performs terminal cleanup without relying on the state below remaining intact.
        guard Task.isCancelled == false, snapshot.engine?.hasUnexpectedStop != true else { return }
        // An orderly end is not path loss, and recording it as such buried real losses in the same
        // counter. What does NOT change is the published status: the replacement session needs its
        // own ticket and loopback port, so the engine is torn down and rebuilt either way, and
        // while it is down there is no tunnel. Claiming otherwise would tell someone their traffic
        // is protected when it is not.
        if graceful {
            TelemetryManager.record("transport_session_ended", relayId: relayID, attributes: attributes)
            SharedConnectionState.appendLog("WSS session ended normally; renewing it")
        } else {
            attributes["reason"] = String(reason.prefix(160))
            TelemetryManager.record("transport_path_lost", relayId: relayID, attributes: attributes)
            SharedConnectionState.appendLog("WSS path ended; reconnecting direct-first")
        }
        SharedConnectionState.setStatus(.connecting, clearRelayLabel: true, clearError: true)
        stopHeartbeatLoop()

        // The engine must release its Reality connection before the loopback adapter disappears.
        guard cleanupActiveTransport(
            cancelMonitor: false,
            expectedTransportEpoch: snapshot.epoch,
            abortIfUnexpectedEngineStopWon: true
        ) != nil else { return }
        TelemetryManager.endSession(reason: graceful ? "wss_session_ended" : "wss_path_lost")

        do {
            // Always re-observe a satisfied physical path after teardown. This is effectively
            // immediate on a healthy path and prevents path-transition races from running broker
            // discovery while the device is transiently offline.
            try await PhysicalNetworkAvailability.waitUntilSatisfied()
            try Task.checkCancellation()
            // Full signed discovery means the descriptor/front set is fresh. connect() always starts
            // at direct Reality and a later WSS rung always obtains a new single-use ticket.
            await connect(completionHandler: nil, isRecovery: true)
        } catch is CancellationError {
            return
        } catch {
            lifecycleQueue.sync { reasserting = false }
            cancelTunnelWithError(error)
        }
    }

    private func finishTransportRecovery(generation: UUID) {
        lifecycleQueue.sync {
            guard transportMonitorGeneration == generation else { return }
            transportRecoveryTask = nil
            transportMonitorGeneration = nil
            // Covers cancellation/early-return paths (engine terminal handoff or user stop). A
            // successful recovery already cleared this at promotion.
            reasserting = false
        }
    }

    private func terminateForActiveLocalFailure(
        _ error: LocalTunnelError,
        relayID: String,
        expectedEngine: (any PacketTunnelProxyEngine)?,
        expectedTransportEpoch: UUID?,
        enforceExpectedState: Bool = true
    ) async {
        guard Task.isCancelled == false else { return }
        let transportEpoch: UUID? = lifecycleQueue.sync {
            guard let currentEpoch = activeTransport.epoch else { return nil }
            if let expectedTransportEpoch, currentEpoch != expectedTransportEpoch { return nil }
            if enforceExpectedState {
                guard
                    activeTransport.relayID == relayID,
                    expectedEngine == nil || activeTransport.engine === expectedEngine
                else { return nil }
            } else if let expectedEngine, activeTransport.engine !== expectedEngine {
                return nil
            }
            return currentEpoch
        }
        guard let transportEpoch else { return }
        stopHeartbeatLoop()
        let message = FailureClassifier.describe(error)
        TelemetryManager.record(
            "connection_failed",
            relayId: relayID,
            attributes: [
                "failure_stage": error.stage,
                "failure_reason": FailureClassifier.classify(error),
                "failure_detail": FailureClassifier.detail(error),
            ]
        )
        guard cleanupActiveTransport(
            cancelMonitor: false,
            expectedTransportEpoch: transportEpoch
        ) != nil else { return }
        let telemetryURLString = TelemetryManager.endSession(reason: "connection_failed")
            ?? AppConfig.telemetryBrokerURL.absoluteString
        try? await TelemetryManager.flush(brokerURL: telemetryURLString)
        // Successfully detaching the epoch transfers terminal ownership to this task. Internal
        // replacement may cancel it after that point, but allowing cancellation to abandon the
        // final provider error would leave a transport-less zombie tunnel. User shutdown still
        // suppresses the error, and an unexpected newer epoch must never be terminated as stale.
        let shouldPublishTerminalFailure = lifecycleQueue.sync {
            lifecycleIsStopping == false && activeTransport.epoch == nil
        }
        guard shouldPublishTerminalFailure else { return }
        SharedConnectionState.fail(message)
        cancelTunnelWithError(error)
    }

    private func closeWssSession(_ expected: any WssNativeSession) {
        lifecycleQueue.sync {
            guard let current = activeTransport.wssSession, current === expected else { return }
            activeTransport.wssSession = nil
            if activeTransport.engine == nil {
                activeTransport.relayID = nil
                activeTransport.accessTransport = AccessTransport.direct
                activeTransport.wssFrontID = nil
                activeTransport.epoch = nil
            }
        }
        expected.close()
    }

    private func closePunchSession(_ expected: any PunchNativeSession) {
        lifecycleQueue.sync {
            guard let current = activeTransport.punchSession, current === expected else { return }
            activeTransport.punchSession = nil
            if activeTransport.engine == nil {
                activeTransport.relayID = nil
                activeTransport.accessTransport = AccessTransport.direct
                activeTransport.wssFrontID = nil
                activeTransport.epoch = nil
            }
        }
        expected.close()
    }

    @discardableResult
    private func cleanupActiveTransport(
        cancelMonitor: Bool = true,
        expectedTransportEpoch: UUID? = nil,
        abortIfUnexpectedEngineStopWon: Bool = false
    ) -> DetachedActiveTransport? {
        let detached: DetachedActiveTransport? = lifecycleQueue.sync {
            if let expectedTransportEpoch, activeTransport.epoch != expectedTransportEpoch {
                return nil
            }
            // This is the linearization point between WSS recovery and an unexpected libbox exit.
            // Marking teardown expected suppresses a later close callback; if the callback already
            // won, recovery leaves the epoch intact for the terminal engine owner.
            let expectedStopClaimed = activeTransport.engine?.prepareForExpectedStop() ?? true
            if abortIfUnexpectedEngineStopWon, expectedStopClaimed == false {
                return nil
            }
            if cancelMonitor {
                transportMonitorTask?.cancel()
                transportMonitorTask = nil
                transportMonitorGeneration = nil
            }
            wssRecoveryGate.clear()
            punchRecoveryGate.clear()
            engineMonitorTask?.cancel()
            engineMonitorTask = nil
            let activeNetworkMonitor = physicalNetworkMonitor
            physicalNetworkMonitor = nil
            let detached = DetachedActiveTransport(
                engine: activeTransport.engine,
                punchSession: activeTransport.punchSession,
                wssSession: activeTransport.wssSession,
                relayID: activeTransport.relayID,
                networkMonitor: activeNetworkMonitor
            )
            activeTransport = ActiveTransportState()
            return detached
        }
        guard let detached else { return nil }
        TunnelTransportCleanup.run(
            stopEngine: { detached.engine?.stop() },
            closeNetworkMonitor: { detached.networkMonitor?.close() },
            closePunch: { detached.punchSession?.close() },
            closeWss: { detached.wssSession?.close() }
        )
        return detached
    }

    /**
     Keeps only candidates whose broker-served country matches `countryCode`. Relays the broker
     hasn't geolocated yet are excluded so a targeted connect never silently lands in the wrong
     country. The broker geolocates each relay's real exit — the app never geolocates relay IPs
     itself (a tunnel relay's `publicHost` would give the hub's location, not the exit's).
     */
    private func filterByCountry(_ candidates: [RelayDescriptor], countryCode: String) -> [RelayDescriptor] {
        let target = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return candidates.filter { relay in
            let code = (relay.countryCode ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            return code == target
        }
    }

    /// Publishes the relay's broker-served location and shows only that label (never the raw IP),
    /// falling back to a generic label while the broker hasn't resolved the relay's geo yet.
    private func applyRelayLocation(_ relay: RelayDescriptor) {
        let resolved = relay.locationLabel()
        SharedConnectionState.setRelayLabel(resolved.isEmpty ? "Unknown location" : resolved)
        recordRecentNode(relay)
    }

    /** Adds the exact connected relay to the "Recents" row (best-effort). */
    private func recordRecentNode(_ relay: RelayDescriptor) {
        let code = (relay.countryCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.isEmpty { return }
        let centroid = CountryGeo.centroid(code)
        let label = relay.locationLabel()
        let relayName = relay.displayName()
        SharedConnectionState.recordRecent(
            RecentNode(
                countryCode: code,
                relayId: relay.id,
                label: label.isEmpty ? (centroid?.name ?? code) : label,
                relayName: relayName,
                latitude: centroid?.latitude ?? relay.latitude ?? 0,
                longitude: centroid?.longitude ?? relay.longitude ?? 0
            )
        )
    }

    private func startHeartbeatLoop() {
        lifecycleQueue.sync {
            guard lifecycleIsStopping == false else { return }
            heartbeatTask?.cancel()
            heartbeatTask = Task {
                while Task.isCancelled == false {
                    await TelemetryManager.sendHeartbeat()
                    let delayMs = UInt64.random(in: AppConfig.heartbeatMinDelayMs...AppConfig.heartbeatMaxDelayMs)
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
            }
        }
    }

    private func stopHeartbeatLoop() {
        lifecycleQueue.sync {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        }
    }

    private func monotonicMilliseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func telemetryInt64(_ value: UInt64) -> Int64 {
        Int64(min(value, UInt64(Int64.max)))
    }

    private func resolveBrokerURL() -> URL {
        guard
            let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = tunnelProtocol.providerConfiguration,
            let urlString = providerConfiguration[AppConfig.providerBrokerURLKey] as? String,
            let url = URL(string: urlString)
        else {
            return AppConfig.defaultBrokerURL
        }
        return url
    }

    private func resolveTargetCountry() -> String? {
        guard
            let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = tunnelProtocol.providerConfiguration,
            let countryCode = providerConfiguration[AppConfig.providerTargetCountryKey] as? String
        else {
            return nil
        }
        let normalized = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.isEmpty ? nil : normalized
    }

    /// Builds the validated split-tunnel rules for this connect attempt, or nil for full-tunnel
    /// behavior. Fail-open (contract §1): a missing/invalid config, `enabled:false`, or missing
    /// bundled `.srs` files always degrade toward the tunnel — a country whose rule-set files are
    /// absent is dropped with a log line, and a config that contributes nothing on iOS (only
    /// `excluded_packages` set) yields nil so the emitted JSON stays byte-identical to today's.
    private func resolveSplitTunnelRules() -> SplitTunnelRules? {
        guard
            let defaults = UserDefaults(suiteName: AppConfig.appGroupIdentifier),
            let config = SplitTunnelConfig.load(from: defaults)
        else {
            return nil
        }
        let ruleSetDirectory = Bundle(for: PacketTunnelProvider.self).resourcePath
        var bypassCountries: [String] = []
        // An automatic country selection is re-derived from the device's CURRENT time zone here,
        // not taken from the stored snapshot. This method runs on every connect attempt including
        // the recovery reconnects that follow a physical-network change, so a phone that
        // auto-selected China in Shanghai stops bypassing geosite-cn as soon as it rebuilds in
        // Berlin — even if the app has not been opened since, and even if the RN foreground
        // re-check never got the chance to run or lost the race with an in-flight recovery.
        let requestedCountries = config.resolvedBypassCountries()
        // Iterating the supported list (not the config order) normalizes to ir,cn order.
        for country in SplitTunnelCountry.supported where requestedCountries.contains(country.code) {
            let hasBothFiles = ruleSetDirectory.map { directory in
                FileManager.default.fileExists(atPath: "\(directory)/\(country.geositeTag).srs")
                    && FileManager.default.fileExists(atPath: "\(directory)/\(country.geoipTag).srs")
            } ?? false
            if hasBothFiles {
                bypassCountries.append(country.code)
            } else {
                SharedConnectionState.appendLog(
                    "split tunneling: rule-set files for \(country.code) are missing; keeping its traffic in the tunnel"
                )
            }
        }
        guard config.bypassLan || bypassCountries.isEmpty == false else { return nil }
        return SplitTunnelRules(
            bypassLan: config.bypassLan,
            bypassCountries: bypassCountries,
            ruleSetDirectory: ruleSetDirectory ?? ""
        )
    }

    private func resolveTargetRelayID() -> String? {
        guard
            let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
            let providerConfiguration = tunnelProtocol.providerConfiguration,
            let relayID = providerConfiguration[AppConfig.providerTargetRelayIDKey] as? String
        else {
            return nil
        }
        let normalized = relayID.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private struct ConnectedRelay {
        let relay: RelayDescriptor
        let tcpLatencyMs: Int64?
        let tunnelStartMs: Int64
        let internetProbeMs: Int64
        let attempts: Int
        let accessTransport: String
        let frontID: String?
        let engine: any PacketTunnelProxyEngine
        let punchSession: (any PunchNativeSession)?
        let wssSession: (any WssNativeSession)?
        let transportEpoch: UUID
    }

    private struct PreparedPunch {
        let session: any PunchNativeSession
        let result: PunchNativeConnectResult
        let transportEpoch: UUID
    }

    private enum AccessTransport {
        static let direct = "direct"
        static let punch = "punch"
        static let wss = "wss"
    }

    private enum TransportMonitorEvent {
        case pathFailure(reason: String, trigger: String, graceful: Bool)
        case localFailure(LocalTunnelError)
    }

    private enum PunchMonitorEvent {
        case pathFailure(reason: String, trigger: String, countTowardBreaker: Bool)
        case localFailure(LocalTunnelError)
    }

    private struct PendingTunnelTasks {
        let connect: Task<Void, Never>?
        let recovery: Task<Void, Never>?
        let terminal: Task<Void, Never>?
        let heartbeat: Task<Void, Never>?
        let engineObserver: Task<Void, Never>?
        let transportObserver: Task<Void, Never>?

        var connectionOwners: [Task<Void, Never>] {
            [connect, recovery, terminal, heartbeat].compactMap { $0 }
        }

        var observers: [Task<Void, Never>] {
            [engineObserver, transportObserver].compactMap { $0 }
        }

        func cancelAll() {
            connect?.cancel()
            recovery?.cancel()
            terminal?.cancel()
            heartbeat?.cancel()
            engineObserver?.cancel()
            transportObserver?.cancel()
        }
    }
}

/// Thread-safe one-shot ownership for a promoted WSS epoch. Native adapter, NWPath and
/// end-to-end health signals may arrive concurrently; exactly one is allowed to launch recovery.
private final class WssRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armedSession: ObjectIdentifier?

    func arm(_ session: any WssNativeSession) {
        lock.lock()
        armedSession = ObjectIdentifier(session)
        lock.unlock()
    }

    func claim(_ session: any WssNativeSession) -> Bool {
        let identifier = ObjectIdentifier(session)
        lock.lock()
        defer { lock.unlock() }
        guard armedSession == identifier else { return false }
        armedSession = nil
        return true
    }

    func clear() {
        lock.lock()
        armedSession = nil
        lock.unlock()
    }
}

/// Thread-safe one-shot ownership for a promoted punch epoch. The native close callback, NWPath,
/// and end-to-end health monitor may all observe the same loss.
private final class PunchRecoveryGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armedSession: ObjectIdentifier?

    func arm(_ session: any PunchNativeSession) {
        lock.lock()
        armedSession = ObjectIdentifier(session)
        lock.unlock()
    }

    func claim(_ session: any PunchNativeSession) -> Bool {
        let identifier = ObjectIdentifier(session)
        lock.lock()
        defer { lock.unlock() }
        guard armedSession == identifier else { return false }
        armedSession = nil
        return true
    }

    func clear() {
        lock.lock()
        armedSession = nil
        lock.unlock()
    }
}

// PacketTunnelError moved to PacketTunnelError.swift so FailureClassifier and its tests can depend
// on it without the NetworkExtension-backed provider. Its cases now carry the underlying Error.
