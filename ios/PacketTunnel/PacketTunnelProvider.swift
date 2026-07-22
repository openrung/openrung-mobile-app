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
        let wssSession: (any WssNativeSession)?
        let relayID: String?
        let networkMonitor: PhysicalNetworkEpochMonitor?
    }

    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "PacketTunnel")
    private let selector = RelaySelector()
    private let wssFallbackPolicy = WssFallbackPolicy(validator: NativeWssFrontValidator())
    private var heartbeatTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var engineMonitorTask: Task<Void, Never>?
    private var wssMonitorTask: Task<Void, Never>?
    private var wssRecoveryTask: Task<Void, Never>?
    private var wssMonitorGeneration: UUID?
    private var physicalNetworkMonitor: PhysicalNetworkEpochMonitor?
    private var activeTransport = ActiveTransportState()
    private var brokerURL = AppConfig.defaultBrokerURL
    /// Native-close, NWPath and health callbacks all enter this queue before they may mutate the
    /// provider's recovery state. WssRecoveryGate then lets only one callback claim an epoch.
    private let lifecycleQueue = DispatchQueue(label: "com.openrung.app.tunnel-lifecycle")
    private let wssRecoveryGate = WssRecoveryGate()
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
            let pending = PendingTunnelTasks(
                connect: connectTask,
                recovery: wssRecoveryTask,
                terminal: terminalLifecycleTask,
                heartbeat: heartbeatTask,
                engineObserver: engineMonitorTask,
                wssObserver: wssMonitorTask
            )
            connectTask = nil
            wssRecoveryTask = nil
            terminalLifecycleTask = nil
            heartbeatTask = nil
            engineMonitorTask = nil
            wssMonitorTask = nil
            wssMonitorGeneration = nil
            pending.cancelAll()
            return pending
        }
        // Cancel any in-flight connect and wait for it to unwind BEFORE tearing down, so it can't
        // assign a new engine or publish .connected for a tunnel we're stopping. connect() checks
        // for cancellation before it commits; a libbox engine it already started (start() is not
        // cancellable) is stopped below, after the await.
        SharedConnectionState.setStatus(.disconnecting)

        let telemetryURLString = AppConfig.telemetryBrokerURL.absoluteString
        Task {
            // Connection-owning tasks must finish before engine teardown. In particular,
            // EmbeddedProxyEngine.start is not cancellable, so stopping it concurrently with a
            // recovery connect can corrupt libbox lifecycle state.
            await TunnelTransportCleanup.drain(pending.connectionOwners)

            let detached = cleanupActiveTransport(cancelMonitor: false)
            if let relayID = detached?.relayID {
                TelemetryManager.record("tunnel_stopped", relayId: relayID)
            }
            TelemetryManager.endSession(reason: "disconnect")
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
        TunnelDiagnostics.clear()
        let brokerURL = resolveBrokerURL()
        let targetCountry = resolveTargetCountry()
        let targetRelayID = resolveTargetRelayID()
        self.brokerURL = brokerURL
        // Telemetry/heartbeat go DIRECT to the origin IP, not the Cloudflare-fronted discovery broker,
        // so high-frequency heartbeats don't burn the Workers free-tier quota (see AppConfig).
        let session = TelemetryManager.beginSession(brokerURL: AppConfig.telemetryBrokerURL.absoluteString)
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
            // Discovery across the broker candidates: a genuine user override is tried strictly
            // first with its full attempt timeout; the defaults race with a staggered start, so
            // a blocked front costs one stagger interval of extra latency (not a full request
            // timeout) and discovery never goes offline while any candidate answers.
            let fetch = try await BrokerClient.firstReachable(
                candidates: AppConfig.brokerCandidates(primary: brokerURL),
                // Targeted connects (country or exact relay) need the full set so the target is present.
                limit: targetCountry == nil && targetRelayID == nil
                    ? AppConfig.relayLimit
                    : AppConfig.directoryRelayLimit,
                clientID: session.clientId,
                sessionID: session.id
            )
            let response = fetch.response
            let brokerFetchMs = Int64((DispatchTime.now().uptimeNanoseconds - brokerStartedNs) / 1_000_000)
            // If a fallback front won discovery — a genuine override is beaten only by FAILING
            // outright (it is tried strictly first); a default primary also when merely slower
            // than its head start — pin the rest of this session's broker traffic (telemetry,
            // heartbeats) to the endpoint that worked.
            if fetch.brokerURL != brokerURL {
                self.brokerURL = fetch.brokerURL
                SharedConnectionState.appendLog("configured broker did not win discovery; using fallback \(fetch.brokerURL.absoluteString)")
            }
            if let geo = await geoLookup {
                TelemetryManager.setGeoInfo(geo)
            }

            let candidates = selector.orderedCandidates(from: response.relays, now: response.serverTime)
            SharedConnectionState.appendLog("broker returned \(response.relays.count) relays; \(candidates.count) usable")
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
                let displayName = (picked.label?.isEmpty == false ? picked.label : nil) ?? picked.id
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
            let connected = try await connectFirstAvailableRelay(rankedCandidates.map(\.relay))

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
            SharedConnectionState.setStatus(.connected, clearRelayLabel: true, clearError: true)
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
            if connected.accessTransport == AccessTransport.wss {
                startWssMonitor(relay: relay)
            }

            // Final, best-effort work only: no connection state or completion follows this await.
            guard Task.isCancelled == false else { return }
            do {
                try await TelemetryManager.flush(brokerURL: AppConfig.telemetryBrokerURL.absoluteString)
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
            TelemetryManager.endSession(reason: "connection_failed")
            try? await TelemetryManager.flush(brokerURL: AppConfig.telemetryBrokerURL.absoluteString)
            guard Task.isCancelled == false else {
                completionHandler?(CancellationError())
                return
            }
            SharedConnectionState.fail(message)
            TunnelDiagnostics.recordError(message)
            logger.error("Failed to start tunnel: \(message, privacy: .public)")
            if isRecovery {
                lifecycleQueue.sync { reasserting = false }
                cancelTunnelWithError(error)
            } else {
                completionHandler?(error)
            }
        }
    }

    private func connectFirstAvailableRelay(_ candidates: [RelayDescriptor]) async throws -> ConnectedRelay {
        var lastError: Error?

        for (index, relay) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                return try await wssFallbackPolicy.connect(
                    relay: relay,
                    attemptDirect: { [self] in
                        try await attemptDirectCandidate(relay, attempt: index + 1)
                    },
                    attemptWss: { [self] front in
                        try await attemptWssCandidate(relay, front: front, attempt: index + 1)
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

    private func attemptDirectCandidate(_ relay: RelayDescriptor, attempt: Int) async throws -> ConnectedRelay {
        let configuration = SingBoxConfiguration(relay: relay)
        do {
            try EmbeddedProxyEngine.preflight(configuration: configuration)
            // Validate the WSS bridge graph before any remote reachability check can unlock ticket
            // acquisition. Port 1 is only a structurally valid placeholder; the actual loopback
            // port returned by wsscore is validated again when that engine is started.
            try EmbeddedProxyEngine.preflight(
                configuration: SingBoxConfiguration(
                    relay: relay,
                    bridgeHost: "127.0.0.1",
                    bridgePort: 1
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

        return try await startTunnel(
            relay: relay,
            configuration: configuration,
            tcpLatencyMs: tcpLatencyMs,
            attempt: attempt,
            accessTransport: AccessTransport.direct,
            frontID: nil
        )
    }

    private func attemptWssCandidate(
        _ relay: RelayDescriptor,
        front: WssFrontDescriptor,
        attempt: Int
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
        guard ticket.isFresh(at: Date()) else {
            closeWssSession(session)
            throw WssTransportError(
                stage: "ticket_expired",
                frontID: front.id,
                underlying: URLError(.userAuthenticationRequired)
            )
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
                bridgePort: endpoint.bridgePort
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
        expectedWssSession: (any WssNativeSession)? = nil,
        expectedTransportEpoch: UUID? = nil
    ) async throws -> ConnectedRelay {
        let proxyEngine = EmbeddedProxyEngine()
        let transportEpoch: UUID? = lifecycleQueue.sync {
            guard lifecycleIsStopping == false, activeTransport.engine == nil else { return nil }
            if let expectedTransportEpoch {
                guard
                    activeTransport.epoch == expectedTransportEpoch,
                    activeTransport.wssSession === expectedWssSession
                else { return nil }
                activeTransport.engine = proxyEngine
                return expectedTransportEpoch
            }
            guard activeTransport.wssSession == nil else { return nil }
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
        let probe: InternetProbeResult
        do {
            probe = try await verifyStartupInternetPath(proxyEngine: proxyEngine)
            guard proxyEngine.hasUnexpectedStop == false else {
                throw LocalTunnelError(
                    stage: "active_tunnel_engine",
                    underlying: PacketTunnelProxyEngineError.engineStartFailed(
                        "libbox stopped during startup verification"
                    )
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if proxyEngine.hasUnexpectedStop {
                throw LocalTunnelError(
                    stage: "active_tunnel_engine",
                    underlying: PacketTunnelProxyEngineError.engineStartFailed(
                        "libbox stopped during startup verification"
                    )
                )
            }
            guard isGenuineRemoteDataPathFailure(error) else {
                throw LocalTunnelError(stage: "internet_probe", underlying: error)
            }
            // Classifying this probe as a remote path failure unlocks direct-to-WSS fallback (and
            // therefore ticket minting). Linearize that decision against libbox's stop callback:
            // if the callback already won, this is a local engine failure; if teardown wins, a
            // later callback is expected because this failed candidate is about to be replaced.
            guard proxyEngine.prepareForExpectedStop() else {
                throw LocalTunnelError(
                    stage: "active_tunnel_engine",
                    underlying: PacketTunnelProxyEngineError.engineStartFailed(
                        "libbox stopped while classifying the startup path failure"
                    )
                )
            }
            if accessTransport == AccessTransport.wss, let frontID {
                throw WssTransportError(stage: "internet_probe", frontID: frontID, underlying: error)
            }
            throw DirectPathError(stage: "internet_probe", underlying: error)
        }
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
            if activeTransport.wssSession == nil {
                activeTransport.epoch = nil
            }
        }
    }

    private func verifyStartupInternetPath(
        proxyEngine: any PacketTunnelProxyEngine
    ) async throws -> InternetProbeResult {
        let probe: PacketTunnelInternetProbe
        do {
            probe = try PacketTunnelInternetProbe(tunnelProvider: self)
        } catch {
            throw LocalTunnelError(stage: "internet_probe_setup", underlying: error)
        }
        return try await withThrowingTaskGroup(of: StartupPathEvent.self) { group in
            group.addTask { .probe(try await probe.verify()) }
            group.addTask { .engineStopped(await proxyEngine.waitForUnexpectedStop()) }
            defer { group.cancelAll() }
            while let event = try await group.next() {
                switch event {
                case .probe(let result):
                    return result
                case .engineStopped(let reason):
                    if let reason {
                        throw LocalTunnelError(
                            stage: "active_tunnel_engine",
                            underlying: PacketTunnelProxyEngineError.engineStartFailed(reason)
                        )
                    }
                    try Task.checkCancellation()
                }
            }
            throw CancellationError()
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

    // MARK: - Active engine / WSS lifecycle and network epochs

    /// Unexpected libbox exit is a local terminal failure under every access transport. In
    /// particular, it must beat a near-simultaneous WSS-close callback and never mint a ticket.
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
            self.reasserting = false
            self.wssMonitorTask?.cancel()
            self.wssMonitorTask = nil
            self.wssMonitorGeneration = nil
            let pendingInitialConnect = self.connectTask
            pendingInitialConnect?.cancel()
            self.connectTask = nil
            let pendingRecovery = self.wssRecoveryTask
            pendingRecovery?.cancel()
            self.wssRecoveryTask = nil
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

    private func startWssMonitor(relay: RelayDescriptor) {
        let replacedMonitor: PhysicalNetworkEpochMonitor? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                let session = activeTransport.wssSession,
                activeTransport.accessTransport == AccessTransport.wss
            else { return nil }
            wssMonitorTask?.cancel()
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
            wssMonitorTask = Task { [weak self] in
                guard let event = await self?.awaitWssMonitorEvent(session: session, monitor: monitor) else {
                    return
                }
                guard Task.isCancelled == false else { return }
                switch event {
                case .pathFailure(let reason, let trigger):
                    self?.requestWssRecovery(
                        trigger: trigger,
                        expectedSession: session,
                        reason: reason
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
    ) async -> WssMonitorEvent? {
        await withTaskGroup(of: WssMonitorEvent?.self) { group in
            group.addTask {
                let reason = await session.waitForUnexpectedClose()
                guard Task.isCancelled == false else { return nil }
                return .pathFailure(reason: reason, trigger: "native_adapter")
            }
            group.addTask {
                do {
                    let reason = try await self.awaitTunnelHealthFailure(monitor: monitor)
                    return .pathFailure(reason: reason, trigger: "tunnel_health")
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
        let probe: PacketTunnelInternetProbe
        do {
            probe = try PacketTunnelInternetProbe(tunnelProvider: self)
        } catch {
            throw LocalTunnelError(stage: "active_tunnel_health_setup", underlying: error)
        }
        var threshold = TunnelHealthFailureThreshold(requiredFailures: 3)
        while true {
            let delayMs = UInt64.random(in: 25_000...35_000)
            try await Task.sleep(nanoseconds: delayMs * 1_000_000)
            do {
                _ = try await probe.verifyOnce()
                threshold.recordSuccess()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isGenuineRemoteDataPathFailure(error) else {
                    throw LocalTunnelError(stage: "active_tunnel_health", underlying: error)
                }
                guard threshold.recordRemoteFailure(), monitor.isSatisfied else { continue }
                return "end-to-end tunnel health probe failed \(threshold.consecutiveFailures) times"
            }
        }
    }

    private func requestWssRecovery(
        trigger: String,
        expectedSession: any WssNativeSession,
        reason: String = "WSS transport epoch ended"
    ) {
        lifecycleQueue.async { [weak self] in
            self?.scheduleWssRecoveryOnLifecycleQueue(
                trigger: trigger,
                expectedSession: expectedSession,
                reason: reason
            )
        }
    }

    private func scheduleWssRecoveryOnLifecycleQueue(
        trigger: String,
        expectedSession: any WssNativeSession,
        reason: String
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
        wssMonitorTask?.cancel()
        wssMonitorTask = nil
        let generation = UUID()
        wssMonitorGeneration = generation
        let pendingInitialConnect = connectTask
        pendingInitialConnect?.cancel()
        connectTask = nil
        wssRecoveryTask?.cancel()
        wssRecoveryTask = Task { [weak self] in
            await pendingInitialConnect?.value
            await self?.recoverWssPath(
                trigger: trigger,
                reason: reason,
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
            self.wssMonitorTask?.cancel()
            self.wssMonitorTask = nil
            self.wssMonitorGeneration = nil
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
        expectedSession: any WssNativeSession,
        generation: UUID
    ) async {
        let snapshot: ActiveTransportSnapshot? = lifecycleQueue.sync {
            guard
                lifecycleIsStopping == false,
                wssMonitorGeneration == generation,
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
        defer { finishWssRecovery(generation: generation) }

        let relayID = snapshot.relayID
        let frontID = snapshot.wssFrontID
        var attributes = [
            "transport": AccessTransport.wss,
            "trigger": trigger,
            "reason": String(reason.prefix(160)),
        ]
        if let frontID { attributes["front_id"] = frontID }
        // A queued local engine-termination path has precedence. Returning here preserves the
        // active state for that owner; if it wins immediately after this check, it awaits this task
        // and then performs terminal cleanup without relying on the state below remaining intact.
        guard Task.isCancelled == false, snapshot.engine?.hasUnexpectedStop != true else { return }
        TelemetryManager.record("transport_path_lost", relayId: relayID, attributes: attributes)
        SharedConnectionState.appendLog("WSS path ended; reconnecting direct-first")
        SharedConnectionState.setStatus(.connecting, clearRelayLabel: true, clearError: true)
        stopHeartbeatLoop()

        // The engine must release its Reality connection before the loopback adapter disappears.
        guard cleanupActiveTransport(
            cancelMonitor: false,
            expectedTransportEpoch: snapshot.epoch,
            abortIfUnexpectedEngineStopWon: true
        ) != nil else { return }
        TelemetryManager.endSession(reason: "wss_path_lost")

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

    private func finishWssRecovery(generation: UUID) {
        lifecycleQueue.sync {
            guard wssMonitorGeneration == generation else { return }
            wssRecoveryTask = nil
            wssMonitorGeneration = nil
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
        TelemetryManager.endSession(reason: "connection_failed")
        try? await TelemetryManager.flush(brokerURL: AppConfig.telemetryBrokerURL.absoluteString)
        // Successfully detaching the epoch transfers terminal ownership to this task. Internal
        // replacement may cancel it after that point, but allowing cancellation to abandon the
        // final provider error would leave a transport-less zombie tunnel. User shutdown still
        // suppresses the error, and an unexpected newer epoch must never be terminated as stale.
        let shouldPublishTerminalFailure = lifecycleQueue.sync {
            lifecycleIsStopping == false && activeTransport.epoch == nil
        }
        guard shouldPublishTerminalFailure else { return }
        SharedConnectionState.fail(message)
        TunnelDiagnostics.recordError(message)
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
                wssMonitorTask?.cancel()
                wssMonitorTask = nil
                wssMonitorGeneration = nil
            }
            wssRecoveryGate.clear()
            engineMonitorTask?.cancel()
            engineMonitorTask = nil
            let activeNetworkMonitor = physicalNetworkMonitor
            physicalNetworkMonitor = nil
            let detached = DetachedActiveTransport(
                engine: activeTransport.engine,
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

    /** Adds the connected relay's broker-served country to the "Recents" row (best-effort). */
    private func recordRecentNode(_ relay: RelayDescriptor) {
        let code = (relay.countryCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if code.isEmpty { return }
        let centroid = CountryGeo.centroid(code)
        let label = relay.locationLabel()
        SharedConnectionState.recordRecent(
            RecentNode(
                countryCode: code,
                label: label.isEmpty ? (centroid?.name ?? code) : label,
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
        let wssSession: (any WssNativeSession)?
        let transportEpoch: UUID
    }

    private enum AccessTransport {
        static let direct = "direct"
        static let wss = "wss"
    }

    private enum WssMonitorEvent {
        case pathFailure(reason: String, trigger: String)
        case localFailure(LocalTunnelError)
    }

    private enum StartupPathEvent: Sendable {
        case probe(InternetProbeResult)
        case engineStopped(String?)
    }

    private struct PendingTunnelTasks {
        let connect: Task<Void, Never>?
        let recovery: Task<Void, Never>?
        let terminal: Task<Void, Never>?
        let heartbeat: Task<Void, Never>?
        let engineObserver: Task<Void, Never>?
        let wssObserver: Task<Void, Never>?

        var connectionOwners: [Task<Void, Never>] {
            [connect, recovery, terminal, heartbeat].compactMap { $0 }
        }

        var observers: [Task<Void, Never>] {
            [engineObserver, wssObserver].compactMap { $0 }
        }

        func cancelAll() {
            connect?.cancel()
            recovery?.cancel()
            terminal?.cancel()
            heartbeat?.cancel()
            engineObserver?.cancel()
            wssObserver?.cancel()
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

// PacketTunnelError moved to PacketTunnelError.swift so FailureClassifier and its tests can depend
// on it without the NetworkExtension-backed provider. Its cases now carry the underlying Error.
