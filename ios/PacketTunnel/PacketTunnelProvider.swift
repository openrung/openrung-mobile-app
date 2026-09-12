import Foundation
import NetworkExtension

/// NetworkExtension lifecycle and OS hooks. connectcore is the sole connection
/// orchestrator; this provider never selects a relay, retries a ticket or runs a
/// health/recovery loop. All mutations below arrive on the process host queue.
final class PacketTunnelProvider: NEPacketTunnelProvider, PacketTunnelEngineOwner {
    let settingsCleanup = EngineTunnelSettingsCleanup(diagnostic: SharedConnectionState.appendLog)
    private let memory = EngineMemoryMonitor()
    private var networkObserver: EngineNetworkObserver?
    private var hasConnected = false
    private var terminalError: Error?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        settingsCleanup.beginProviderStart()
        memory.start()
        memory.mark("provider-start")
        IOSConnectcore.host.start(owner: self, broker: resolveBrokerURL().absoluteString,
            country: resolveTargetCountry() ?? "", relay: resolveTargetRelayID() ?? "") { [self] error in
                if error != nil { memory.stop() }
                completionHandler(error)
            }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        settingsCleanup.beginProviderStop()
        IOSConnectcore.host.stop(owner: self) { [self] in
            memory.stop()
            completionHandler()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        memory.mark("sleep")
        IOSConnectcore.host.sleep(owner: self, completion: completionHandler)
    }

    override func wake() { memory.mark("wake"); IOSConnectcore.host.wake(owner: self) }

    func observeNetwork(_ receive: @escaping (EngineNetworkSnapshot) -> Void) {
        hasConnected = false
        terminalError = nil
        reasserting = false
        TelemetrySessionStore.save(nil)
        SharedConnectionState.setBrokerURL(resolveBrokerURL().absoluteString)
        SharedConnectionState.setStatus(.preparing, clearRelayLabel: true, clearError: true)
        networkObserver = EngineNetworkObserver(receive: receive)
    }

    func closeNetworkObservation() { networkObserver?.close(); networkObserver = nil }

    func receiveEngineEvent(_ event: EngineEvent) {
        if event.kind == "log", let line = event.payload["Line"] as? String {
            SharedConnectionState.appendLog(line)
            return
        }
        guard let projection = EngineStateProjection(event) else { return }
        reasserting = hasConnected && [.preparing, .connecting].contains(projection.status)
        if projection.status == .connected { hasConnected = true; reasserting = false }
        memory.mark(projection.status.rawValue)
        SharedConnectionState.applyEngineState(projection)
        // Preserve the existing cross-process session storage format for getIdentity.
        if let id = projection.sessionID {
            let previous = TelemetrySessionStore.current()
            let same = previous?.id == id
            TelemetrySessionStore.save(TelemetrySession(id: id, clientId: ClientIdentity.getOrCreate(),
                brokerURL: resolveBrokerURL().absoluteString,
                startedElapsedMs: same ? previous!.startedElapsedMs : MonotonicClock.nowMs(),
                relayId: projection.relayID,
                connectedElapsedMs: projection.status == .connected ? (same ? previous?.connectedElapsedMs : nil) ?? MonotonicClock.nowMs() : nil))
        } else { TelemetrySessionStore.save(nil) }
    }

    func engineStopping() {
        reasserting = false
        SharedConnectionState.setStatus(.disconnecting)
    }

    func engineStopped(error: Error?, startPending: Bool) {
        memory.stop()
        reasserting = false
        TelemetrySessionStore.save(nil)
        if let error {
            terminalError = error
            SharedConnectionState.fail(error.localizedDescription)
            // An outstanding start completion reports the failure to NE.
            // Cancel only after that completion has already succeeded.
            if !startPending { cancelTunnelWithError(error) }
        } else if terminalError == nil {
            SharedConnectionState.setStatus(.disconnected, clearRelayLabel: true, clearError: true)
        }
    }

    func engineTeardownFailed(_ error: Error, startPending: Bool) {
        // The process host retains this provider and refuses another run. Asking
        // NetworkExtension to end the tunnel lets the OS reclaim duplicated fds.
        engineStopped(error: error, startPending: startPending)
    }

    func settingsJSON() throws -> String {
        let rules = resolveSplitTunnelRules()
        return try EngineTunnelSettings.json(rules: rules)
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

}
