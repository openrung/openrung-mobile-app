import Foundation
import NetworkExtension

struct LoadedTunnelManager {
    var manager: NETunnelProviderManager
    var created: Bool
}

/// Owns the single `NETunnelProviderManager` the host app is allowed to use. The widget
/// extension never touches this type. Automatic relay selection is not implemented here:
/// a nil country and nil relay id are the existing contract, and connectcore chooses.
@MainActor
final class TunnelControl {
    static let shared = TunnelControl()

    private(set) var manager: NETunnelProviderManager?
    private(set) var controlEpoch = 0
    private var commandInFlight = false
    private var lastCommandAt: Date?
    /// The VPN module refreshes its React Native snapshot when the tunnel is poked.
    var onActivity: (@MainActor () -> Void)?

    private init() {}

    var hasManager: Bool { manager != nil }
    var isCommandInFlight: Bool { commandInFlight }
    var systemStatus: NEVPNStatus { manager?.connection.status ?? .invalid }

    func hasRecentCommand(within seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let lastCommandAt else { return false }
        return now.timeIntervalSince(lastCommandAt) < seconds
    }

    @discardableResult
    func beginCommand(now: Date = Date()) -> Int {
        controlEpoch += 1
        commandInFlight = true
        lastCommandAt = now
        return controlEpoch
    }

    func endCommand(epoch: Int) {
        guard controlEpoch == epoch else { return }
        commandInFlight = false
    }

    static var canUseNetworkExtension: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    func adopt(_ manager: NETunnelProviderManager) {
        self.manager = manager
    }

    /// `prepare()` can return an already-saved profile without going through `configure`.
    func noteProfileSavedIfConfigured() {
        guard let manager, manager.protocolConfiguration != nil, manager.isEnabled else { return }
        guard let store = WidgetAppGroup.store else { return }
        WidgetPreferences.setProfileReady(true, store)
        WidgetTimelineReloadHook.reload()
    }

    func loadInstalledManager() async throws {
        guard Self.canUseNetworkExtension else { return }
        let loaded = try await loadOrCreateManager()
        manager = loaded.manager
        publishProfileReady(loaded)
    }

    /// Manual connect from React Native. `switchRelay` preserves the production stop → 350 ms →
    /// reconfigure → start dance when a tunnel is already up or working.
    func connect(
        brokerUrl: String,
        targetCountry: String?,
        targetRelayId: String?,
        switchRelay: Bool
    ) async throws {
        let epoch = beginCommand()
        defer { endCommand(epoch: epoch) }
        try await runStart(
            epoch: epoch,
            brokerUrl: brokerUrl,
            targetCountry: Self.normalizedCountryCode(targetCountry),
            targetRelayID: Self.normalizedRelayID(targetRelayId),
            switchRelay: switchRelay
        )
    }

    func disconnect() {
        let epoch = beginCommand()
        defer { endCommand(epoch: epoch) }
        manager?.connection.stopVPNTunnel()
        onActivity?()
    }

    /// Widget handoff. Starts the same path as the in-app Connect button (nil country, nil
    /// relay) only when a profile is already saved and the OS tunnel is idle. A busy or live
    /// tunnel, including a manual country selection, is left alone.
    func startAutoBestRelayIfIdle(now: Date = Date()) async {
        guard !isCommandInFlight else { return }
        let recent = hasRecentCommand(
            within: TimeInterval(WidgetConnectPolicy.duplicateStartSuppressionMillis) / 1000,
            now: now
        )
        do {
            guard Self.canUseNetworkExtension else {
                throw AppError.networkExtensionUnavailableInSimulator
            }
            let loaded = try await loadOrCreateManager()
            manager = loaded.manager
            let savedProfile = Self.isSavedProfile(loaded)
            publishProfileReady(loaded)
            let status = WidgetSystemStatus(loaded.manager.connection.status)
            guard WidgetConnectPolicy.shouldStart(
                profileReady: savedProfile,
                systemStatus: status,
                commandInFlight: isCommandInFlight,
                recentCommand: recent
            ) else {
                return
            }
            let epoch = beginCommand(now: now)
            defer { endCommand(epoch: epoch) }
            try await runStart(
                epoch: epoch,
                brokerUrl: AppConfig.defaultBrokerURL.absoluteString,
                targetCountry: nil,
                targetRelayID: nil,
                switchRelay: false
            )
        } catch {
            SharedConnectionState.fail(AppError.message(for: error))
            onActivity?()
        }
    }

    func loadOrCreateManager() async throws -> LoadedTunnelManager {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        if let existing = managers.first(where: {
            $0.localizedDescription == AppConfig.vpnProfileName
        }) {
            return LoadedTunnelManager(manager: existing, created: false)
        }
        if let existing = managers.first(where: {
            $0.localizedDescription == AppConfig.legacyVPNProfileName
        }) {
            // The next configure/save migrates profiles created before the terminology change.
            existing.localizedDescription = AppConfig.vpnProfileName
            return LoadedTunnelManager(manager: existing, created: false)
        }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = AppConfig.vpnProfileName
        return LoadedTunnelManager(manager: manager, created: true)
    }

    func configure(
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
        self.manager = manager
        if let store = WidgetAppGroup.store {
            WidgetPreferences.setProfileReady(true, store)
            WidgetTimelineReloadHook.reload()
        }
    }

    private func runStart(
        epoch: Int,
        brokerUrl: String,
        targetCountry: String?,
        targetRelayID: String?,
        switchRelay: Bool
    ) async throws {
        guard controlEpoch == epoch else { return }
        guard Self.canUseNetworkExtension else {
            throw AppError.networkExtensionUnavailableInSimulator
        }
        let brokerURL = URL(string: brokerUrl) ?? AppConfig.defaultBrokerURL
        let loaded = try await loadOrCreateManager()
        guard controlEpoch == epoch else { return }
        let active = loaded.manager
        manager = active
        if switchRelay {
            active.connection.stopVPNTunnel()
            onActivity?()
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard controlEpoch == epoch else { return }
        }
        try await configure(
            manager: active,
            brokerURL: brokerURL,
            targetCountry: targetCountry,
            targetRelayID: targetRelayID
        )
        guard controlEpoch == epoch else { return }
        try active.connection.startVPNTunnel()
        onActivity?()
    }

    private func publishProfileReady(_ loaded: LoadedTunnelManager) {
        guard let store = WidgetAppGroup.store else { return }
        WidgetPreferences.setProfileReady(Self.isSavedProfile(loaded), store)
        WidgetTimelineReloadHook.reload()
    }

    private static func isSavedProfile(_ loaded: LoadedTunnelManager) -> Bool {
        loaded.created == false
            && loaded.manager.protocolConfiguration != nil
            && loaded.manager.isEnabled
    }

    static func normalizedCountryCode(_ countryCode: String?) -> String? {
        guard let normalized = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              normalized.isEmpty == false
        else {
            return nil
        }
        return normalized
    }

    static func normalizedRelayID(_ relayID: String?) -> String? {
        let trimmed = relayID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, trimmed.isEmpty == false else { return nil }
        return trimmed
    }
}

extension WidgetSystemStatus {
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid:
            self = .invalid
        case .disconnected:
            self = .disconnected
        case .connecting:
            self = .connecting
        case .connected:
            self = .connected
        case .reasserting:
            self = .reasserting
        case .disconnecting:
            self = .disconnecting
        @unknown default:
            // Fail closed: an unrecognised OS state must not start a second tunnel.
            self = .connecting
        }
    }
}

enum AppError: LocalizedError {
    case networkExtensionUnavailableInSimulator

    var errorDescription: String? {
        switch self {
        case .networkExtensionUnavailableInSimulator:
            return "The iOS simulator cannot install or start a Packet Tunnel VPN profile. Run on a signed physical iPhone with the Network Extension packet-tunnel entitlement to test Connect."
        }
    }

    static func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "NEConfigurationErrorDomain", nsError.code == 11 {
            return "Network Extension preferences are unavailable. On the simulator this is expected; on a real iPhone, confirm the app and Packet Tunnel extension are signed with the packet-tunnel entitlement and matching App Group."
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
