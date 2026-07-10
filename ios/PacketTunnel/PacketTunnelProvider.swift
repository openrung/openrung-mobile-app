import Foundation
import NetworkExtension
import OSLog

/// The iOS equivalent of Android's `OpenRungVpnService`: it owns the connection state machine,
/// per-relay reachability/engine/internet-probe flow, geo relay-label resolution, lifecycle
/// telemetry, and the heartbeat loop. Rich state is published to the app via `SharedConnectionState`.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "PacketTunnel")
    private let selector = RelaySelector()
    private var engine: PacketTunnelProxyEngine?
    private var heartbeatTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var activeRelayID: String?
    private var brokerURL = AppConfig.defaultBrokerURL

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        connectTask = Task { await connect(completionHandler: completionHandler) }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        // Cancel any in-flight connect and wait for it to unwind BEFORE tearing down, so it can't
        // assign a new engine or publish .connected for a tunnel we're stopping. connect() checks
        // for cancellation before it commits; a libbox engine it already started (start() is not
        // cancellable) is stopped below, after the await.
        let pendingConnect = connectTask
        connectTask = nil
        pendingConnect?.cancel()
        SharedConnectionState.setStatus(.disconnecting)

        let telemetryURLString = AppConfig.telemetryBrokerURL.absoluteString
        Task {
            await pendingConnect?.value

            if let relayID = activeRelayID {
                TelemetryManager.record("tunnel_stopped", relayId: relayID)
            }
            activeRelayID = nil
            TelemetryManager.endSession(reason: "disconnect")

            engine?.stop()
            engine = nil
            SharedConnectionState.setStatus(.disconnected, clearRelayLabel: true, clearError: true)

            try? await TelemetryManager.flush(brokerURL: telemetryURLString)
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        // Pause the engine while the device sleeps so iOS doesn't terminate the extension for CPU
        // wakeups; libbox schedules its own auto-wake. Without this the extension can be silently
        // killed while SharedConnectionState still reports .connected.
        engine?.pause()
        completionHandler()
    }

    override func wake() {
        engine?.wake()
    }

    // MARK: - Connection flow

    private func connect(completionHandler: @escaping (Error?) -> Void) async {
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
                SharedConnectionState.appendLog("connecting to a volunteer in \(countryName)")
                failureStage = "relay_geo_filter"
                targetedCandidates = filterByCountry(candidates, countryCode: targetCountry)
                guard targetedCandidates.isEmpty == false else {
                    throw PacketTunnelError.noRelayInCountry(countryName)
                }
            } else {
                targetedCandidates = candidates
            }

            failureStage = "relay_connect"
            let connected = try await connectFirstAvailableRelay(targetedCandidates)

            // A stop may have arrived while we were connecting. Don't publish .connected or start
            // the heartbeat for a tunnel that's being torn down; stopTunnel awaited this task and
            // stops the engine connectFirstAvailableRelay assigned.
            try Task.checkCancellation()

            let relay = connected.relay
            activeRelayID = relay.id
            TelemetryManager.markConnected(relayId: relay.id)
            SharedConnectionState.setStatus(.connected, clearRelayLabel: true, clearError: true)
            applyRelayLocation(relay)
            TelemetryManager.record(
                "connection_succeeded",
                relayId: relay.id,
                measurements: [
                    "broker_fetch_ms": brokerFetchMs,
                    "relay_tcp_ms": connected.tcpLatencyMs,
                    "tunnel_start_ms": connected.tunnelStartMs,
                    "internet_probe_ms": connected.internetProbeMs,
                    "relay_attempts": Int64(connected.attempts),
                ]
            )
            try? await TelemetryManager.flush(brokerURL: AppConfig.telemetryBrokerURL.absoluteString)
            startHeartbeatLoop()

            logger.info("Connected through relay \(relay.id, privacy: .public)")
            completionHandler(nil)
        } catch is CancellationError {
            // Stopped mid-connect. Leave engine teardown and the .disconnected status to stopTunnel
            // (which awaited this task); don't record a failure or publish an error for a
            // user-initiated stop.
            completionHandler(CancellationError())
        } catch {
            engine?.stop()
            engine = nil
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
            SharedConnectionState.fail(message)
            TunnelDiagnostics.recordError(message)
            logger.error("Failed to start tunnel: \(message, privacy: .public)")
            completionHandler(error)
        }
    }

    private func connectFirstAvailableRelay(_ candidates: [RelayDescriptor]) async throws -> ConnectedRelay {
        var lastError: Error?

        for (index, relay) in candidates.enumerated() {
            try Task.checkCancellation()
            do {
                SharedConnectionState.appendLog("trying relay \(relay.id) at \(relay.publicHost):\(relay.publicPort)")
                SharedConnectionState.appendLog("checking relay TCP reachability")

                let tcpLatencyMs: Int64
                do {
                    tcpLatencyMs = try await RelayReachability.checkTcp(relay)
                } catch is CancellationError {
                    // A racing stop cancelled the probe; propagate cancellation rather than masking
                    // it as an unreachable relay (handled by the outer cancellation catch).
                    throw CancellationError()
                } catch {
                    // Carry the real cause so the failure classifies on its merits (timeout,
                    // connection_refused, …) instead of a generic reachability token.
                    throw PacketTunnelError.relayUnreachable(host: relay.publicHost, port: relay.publicPort, underlying: error)
                }

                let proxyEngine = EmbeddedProxyEngine()
                engine = proxyEngine
                let tunnelStartedNs = DispatchTime.now().uptimeNanoseconds
                try await proxyEngine.start(relay: relay, tunnelProvider: self)
                let tunnelStartMs = Int64((DispatchTime.now().uptimeNanoseconds - tunnelStartedNs) / 1_000_000)

                SharedConnectionState.appendLog("verifying internet access through the VPN")
                let probe = try await InternetProbe().verify()
                SharedConnectionState.appendLog("internet access verified in \(probe.durationMs) ms")

                return ConnectedRelay(
                    relay: relay,
                    tcpLatencyMs: tcpLatencyMs,
                    tunnelStartMs: tunnelStartMs,
                    internetProbeMs: probe.durationMs,
                    attempts: index + 1
                )
            } catch is CancellationError {
                // A racing stop cancelled us; stop the engine this attempt may have started and
                // propagate cancellation instead of trying the next relay.
                engine?.stop()
                engine = nil
                throw CancellationError()
            } catch {
                lastError = error
                var attributes = ["error_type": FailureClassifier.errorType(error)]
                let reason = FailureClassifier.classify(error)
                if reason.isEmpty == false { attributes["failure_reason"] = reason }
                let detail = FailureClassifier.detail(error)
                if detail.isEmpty == false { attributes["failure_detail"] = detail }
                TelemetryManager.record(
                    "relay_attempt_failed",
                    relayId: relay.id,
                    attributes: attributes,
                    measurements: ["attempt": Int64(index + 1)]
                )
                SharedConnectionState.appendLog("relay \(relay.id) failed: \(FailureClassifier.describe(error))")
                engine?.stop()
                engine = nil
            }
        }

        // Carry the last error itself (not just its message) so connection_failed classifies on the
        // real root cause instead of this generic wrapper.
        throw PacketTunnelError.allRelaysFailed(lastError)
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
        heartbeatTask?.cancel()
        heartbeatTask = Task {
            while Task.isCancelled == false {
                await TelemetryManager.sendHeartbeat()
                let delayMs = UInt64.random(in: AppConfig.heartbeatMinDelayMs...AppConfig.heartbeatMaxDelayMs)
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
            }
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
        let tcpLatencyMs: Int64
        let tunnelStartMs: Int64
        let internetProbeMs: Int64
        let attempts: Int
    }
}

// PacketTunnelError moved to PacketTunnelError.swift so FailureClassifier and its tests can depend
// on it without the NetworkExtension-backed provider. Its cases now carry the underlying Error.
