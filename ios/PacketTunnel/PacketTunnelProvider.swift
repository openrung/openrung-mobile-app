import Foundation
import NetworkExtension
import notify

/// NetworkExtension lifecycle and OS hooks. connectcore is the sole connection
/// orchestrator; this provider never selects a relay, retries a ticket or runs a
/// health/recovery loop. All mutations below arrive on the process host queue.
final class PacketTunnelProvider: NEPacketTunnelProvider, PacketTunnelEngineOwner {
    let settingsCleanup = EngineTunnelSettingsCleanup(diagnostic: SharedConnectionState.appendLog)
    private let memory = EngineMemoryMonitor()
    private var networkObserver: EngineNetworkObserver?
    private var hasConnected = false
    private var terminalError: Error?
    private var widgetDisconnectToken: Int32 = NOTIFY_TOKEN_INVALID

    deinit {
        if widgetDisconnectToken != NOTIFY_TOKEN_INVALID { notify_cancel(widgetDisconnectToken) }
    }

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        observeWidgetDisconnect()
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

    /// The home-screen widget's Disconnect control (`WidgetDisconnectRequest`): the widget cannot
    /// reach a tunnel manager and must not launch the app, so the tunnel ends itself. The Darwin
    /// notification is only a wake-up; the request is the app-group key, which only this app's
    /// own processes can write.
    private func observeWidgetDisconnect() {
        // A request from before this tunnel existed is not for it.
        WidgetDisconnectRequest.clear()
        guard widgetDisconnectToken == NOTIFY_TOKEN_INVALID else { return }
        notify_register_dispatch(
            WidgetSharedState.disconnectNotificationName, &widgetDisconnectToken, .global(qos: .userInitiated)
        ) { [weak self] _ in
            self?.handleWidgetDisconnect(attemptsLeft: 3)
        }
    }

    private func handleWidgetDisconnect(attemptsLeft: Int) {
        guard IOSConnectcore.host.currentOwner() === self else { return }
        guard WidgetDisconnectRequest.consume() else {
            // The widget's write can trail its notification across processes; look again shortly.
            guard attemptsLeft > 1 else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                self?.handleWidgetDisconnect(attemptsLeft: attemptsLeft - 1)
            }
            return
        }
        SharedConnectionState.appendLog("Disconnect requested from the home-screen widget")
        IOSConnectcore.host.stop(owner: self) { [self] in
            memory.stop()
            // The engine is down and the snapshot says so; have NetworkExtension retire the tunnel.
            cancelTunnelWithError(nil)
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
    }

    func engineStopping() {
        reasserting = false
        SharedConnectionState.setStatus(.disconnecting)
    }

    func engineStopped(error: Error?, startPending: Bool) {
        memory.stop()
        reasserting = false
        if let error {
            terminalError = error
            SharedConnectionState.fail(error.localizedDescription, code: (error as? EngineFailure)?.code)
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
