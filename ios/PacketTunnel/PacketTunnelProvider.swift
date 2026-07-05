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
    private var activeRelayID: String?
    private var brokerURL = AppConfig.defaultBrokerURL

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { await connect(completionHandler: completionHandler) }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        SharedConnectionState.setStatus(.disconnecting)

        if let relayID = activeRelayID {
            TelemetryManager.record("tunnel_stopped", relayId: relayID)
        }
        activeRelayID = nil
        TelemetryManager.endSession(reason: "disconnect")

        engine?.stop()
        engine = nil
        // Belt-and-braces for engine-less failure paths: the engine's own stop() already clears.
        SharedTrafficState.clear()
        SharedConnectionState.setStatus(.disconnected, clearRelayLabel: true, clearError: true)

        let telemetryURLString = AppConfig.telemetryBrokerURL.absoluteString
        Task {
            try? await TelemetryManager.flush(brokerURL: telemetryURLString)
            completionHandler()
        }
    }

    // MARK: - Connection flow

    private func connect(completionHandler: @escaping (Error?) -> Void) async {
        // Compact the persisted runtime log here so the hot append path stays append-only.
        RuntimeLogStore.compactIfNeeded()
        TunnelDiagnostics.clear()
        let brokerURL = resolveBrokerURL()
        let targetCountry = resolveTargetCountry()
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
            // Tries each broker candidate in order so a blocked primary endpoint doesn't take
            // discovery offline.
            let fetch = try await BrokerClient.firstReachable(
                candidates: AppConfig.brokerCandidates(primary: brokerURL),
                limit: targetCountry == nil ? AppConfig.relayLimit : AppConfig.directoryRelayLimit,
                clientID: session.clientId,
                sessionID: session.id
            )
            let response = fetch.response
            let brokerFetchMs = Int64((DispatchTime.now().uptimeNanoseconds - brokerStartedNs) / 1_000_000)
            // If the primary broker was unreachable and a fallback served the list, pin the rest of
            // this session's broker traffic (telemetry, heartbeats) to the endpoint that worked.
            if fetch.brokerURL != brokerURL {
                self.brokerURL = fetch.brokerURL
                SharedConnectionState.appendLog("primary broker unreachable; using fallback \(fetch.brokerURL.absoluteString)")
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
            if let targetCountry {
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
        } catch {
            engine?.stop()
            engine = nil
            let message = Self.describe(error)
            TelemetryManager.record(
                "connection_failed",
                attributes: ["failure_stage": failureStage, "error_type": Self.errorType(error)]
            )
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
            do {
                SharedConnectionState.appendLog("trying relay \(relay.id) at \(relay.publicHost):\(relay.publicPort)")
                SharedConnectionState.appendLog("checking relay TCP reachability")

                let tcpLatencyMs: Int64
                do {
                    tcpLatencyMs = try await RelayReachability.checkTcp(relay)
                } catch {
                    throw PacketTunnelError.relayUnreachable(host: relay.publicHost, port: relay.publicPort)
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
            } catch {
                lastError = error
                TelemetryManager.record(
                    "relay_attempt_failed",
                    relayId: relay.id,
                    attributes: ["error_type": Self.errorType(error)],
                    measurements: ["attempt": Int64(index + 1)]
                )
                SharedConnectionState.appendLog("relay \(relay.id) failed: \(Self.describe(error))")
                engine?.stop()
                engine = nil
            }
        }

        throw PacketTunnelError.allRelaysFailed(lastError.map(Self.describe))
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

    private static func errorType(_ error: Error) -> String {
        String(describing: type(of: error))
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private struct ConnectedRelay {
        let relay: RelayDescriptor
        let tcpLatencyMs: Int64
        let tunnelStartMs: Int64
        let internetProbeMs: Int64
        let attempts: Int
    }
}

enum PacketTunnelError: LocalizedError {
    case noUsableRelay
    case noRelayInCountry(String)
    case relayUnreachable(host: String, port: Int)
    case allRelaysFailed(String?)

    var errorDescription: String? {
        switch self {
        case .noUsableRelay:
            return "No usable VLESS Reality Vision direct-exit relay is available."
        case .noRelayInCountry(let countryName):
            return "No volunteer relay available in \(countryName) right now."
        case .relayUnreachable(let host, let port):
            return "Relay \(host):\(port) is not reachable from this device."
        case .allRelaysFailed(let message):
            if let message {
                return "All relay connection attempts failed. Last error: \(message)"
            }
            return "All relay connection attempts failed."
        }
    }
}
