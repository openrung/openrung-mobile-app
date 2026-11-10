import NetworkExtension

/// The app's one VPN profile (`NETunnelProviderManager`, found by its localizedDescription): how it
/// is found, written and, for the widget, started. One implementation for the RN bridge
/// (`OpenRungVpnModule`) and for the widget's Connect when the app runs in the background with no
/// JavaScript (`WidgetBackgroundConnect`).
enum VpnProfile {
    /// False on the simulator, where NetworkExtension is unavailable by design.
    static var canUseNetworkExtension: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// The saved profile, nil when the OS has none for this app.
    static func existing() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            $0.localizedDescription == AppConfig.vpnProfileName
        }) {
            return existing
        }
        if let existing = managers.first(where: {
            $0.localizedDescription == AppConfig.legacyVPNProfileName
        }) {
            // The next configure/save migrates profiles created before the terminology change.
            existing.localizedDescription = AppConfig.vpnProfileName
            return existing
        }
        return nil
    }

    /// The saved profile, or a new unsaved one. Saving a new one (`configure`) is what brings up
    /// the OS VPN-consent dialog, so that only ever happens with the app in front.
    static func loadOrCreate() async throws -> NETunnelProviderManager {
        if let existing = try await existing() {
            return existing
        }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = AppConfig.vpnProfileName
        return manager
    }

    static func configure(
        manager: NETunnelProviderManager,
        brokerURL: URL,
        targetCountry: String?,
        targetRelayID: String? = nil
    ) async throws {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = AppConfig.packetTunnelBundleIdentifier
        tunnelProtocol.serverAddress = brokerURL.host ?? brokerURL.absoluteString
        var providerConfiguration = [AppConfig.providerBrokerURLKey: brokerURL.absoluteString]
        if let targetCountry {
            providerConfiguration[AppConfig.providerTargetCountryKey] = targetCountry
        }
        if let targetRelayID {
            providerConfiguration[AppConfig.providerTargetRelayIDKey] = targetRelayID
        }
        tunnelProtocol.providerConfiguration = providerConfiguration
        manager.protocolConfiguration = tunnelProtocol
        manager.isEnabled = true
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
    }

    /// The widget's Connect, run natively because the app may have been launched in the background
    /// just for this, with no JavaScript. It is what `prepareAndConnectVpn(null, null)` comes to for
    /// a saved profile: the default broker, no target country or relay, then start. It never
    /// creates a profile (that needs the consent dialog) and starts only from a fully down state
    /// (`WidgetConnectPolicy`), so it can neither switch nor restart a running tunnel.
    @MainActor
    static func startFromWidget() async -> WidgetBackgroundConnect.Outcome {
        guard canUseNetworkExtension else { return .unavailable }
        do {
            guard let manager = try await existing(), manager.protocolConfiguration != nil else {
                return .unavailable
            }
            let systemStatus = manager.connection.status
            var snapshot = SharedConnectionState.snapshot()
            snapshot.reconcileSystemTunnel(isDown: systemStatus == .disconnected || systemStatus == .invalid)
            let decision = WidgetConnectPolicy.decide(
                sharedStatus: snapshot.status,
                systemTunnel: WidgetConnectPolicy.SystemTunnel(systemStatus)
            )
            guard decision == .start else { return .ignored }
            try await configure(manager: manager, brokerURL: AppConfig.defaultBrokerURL, targetCountry: nil)
            try manager.connection.startVPNTunnel()
            return .started
        } catch {
            return .unavailable
        }
    }
}
