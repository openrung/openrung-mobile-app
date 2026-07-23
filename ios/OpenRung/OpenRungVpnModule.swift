import Foundation
import NetworkExtension
import React

/// React Native bridge for the OpenRung VPN (contract §3). Port of the manager/state half of the
/// production `AppViewModel`: owns the `NETunnelProviderManager` (found by localizedDescription
/// "OpenRung VPN"), mirrors the rich connection state the PacketTunnel extension
/// publishes via `SharedConnectionState` (re-read on a Darwin notification), watches
/// `.NEVPNStatusDidChange`, and reports every change to JS as an `openrungStateChanged` event.
@objc(OpenRungVpn)
final class OpenRungVpnModule: RCTEventEmitter {
    private static let stateChangedEvent = "openrungStateChanged"

    private var manager: NETunnelProviderManager?
    private var vpnStatus: NEVPNStatus = .invalid
    private var status: ConnectionStatus = .disconnected
    private var relayLabel: String?
    private var lastError: String?
    private var logLines: [String] = []
    private var recentRegions: [RecentNode] = []
    private var hasListeners = false
    private var vpnStatusObserver: NSObjectProtocol?
    /// Bumped by every explicit connect/disconnect and by a split-tunnel reapply. The reapply
    /// dance stops the tunnel and restarts it after a 350 ms delay; it captures this value before
    /// sleeping and aborts the restart if a newer command (e.g. the user tapping Disconnect)
    /// arrived meanwhile — so a settings reapply never resurrects a tunnel the user just stopped.
    private var controlEpoch = 0

    override init() {
        super.init()
        // What the app shows on a cold launch: a stale CONNECTED never survives, and the relay
        // label (which could leak a prior relay) is dropped until re-resolved.
        apply(SharedConnectionState.sanitizedForColdStart(), emit: false)
        observeVPNStatus()
        observeSharedState()
        Task { @MainActor in
            await self.loadExistingManager()
        }
    }

    deinit {
        if let vpnStatusObserver {
            NotificationCenter.default.removeObserver(vpnStatusObserver)
        }
        CFNotificationCenterRemoveEveryObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    // MARK: - RCTEventEmitter

    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String]! { [Self.stateChangedEvent] }

    override func startObserving() {
        hasListeners = true
        // Sync JS with the current snapshot as soon as it subscribes.
        Task { @MainActor in
            self.emitStateChanged()
        }
    }

    override func stopObserving() {
        hasListeners = false
    }

    // MARK: - Bridged methods (contract §3)

    /// iOS half of `prepare()`: load-or-create the `NETunnelProviderManager` and save it (saving a
    /// freshly created configuration is what triggers the OS VPN-consent dialog). Resolves true
    /// when usable; false on the simulator, where NetworkExtension is unavailable by design.
    @objc(prepare:rejecter:)
    func prepare(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            guard Self.canUseNetworkExtension else {
                resolve(false)
                return
            }
            do {
                let manager = try await self.loadOrCreateManager()
                if manager.protocolConfiguration == nil {
                    try await self.configure(manager: manager, brokerURL: AppConfig.defaultBrokerURL, targetCountry: nil)
                }
                self.manager = manager
                self.refreshVPNStatus()
                resolve(true)
            } catch {
                reject("prepare_failed", AppError.message(for: error), error)
            }
        }
    }

    /// Start (or switch) the tunnel. Mirrors `AppViewModel.connect(countryCode:)` including the
    /// production relay-switch dance: stop → 350 ms → reconfigure → start.
    @objc(connect:targetCountry:targetRelayId:resolver:rejecter:)
    func connect(
        _ brokerUrl: String,
        targetCountry: String?,
        targetRelayId: String?,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            self.controlEpoch += 1
            let normalizedCountry = Self.normalizedCountryCode(targetCountry)
            let normalizedRelayID = targetRelayId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let shouldSwitchRelay = self.status.isConnected || self.status.isWorking
            do {
                guard Self.canUseNetworkExtension else {
                    throw AppError.networkExtensionUnavailableInSimulator
                }
                let brokerURL = URL(string: brokerUrl) ?? AppConfig.defaultBrokerURL
                let manager = try await self.loadOrCreateManager()
                if shouldSwitchRelay {
                    manager.connection.stopVPNTunnel()
                    self.refreshVPNStatus()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                }
                try await self.configure(
                    manager: manager,
                    brokerURL: brokerURL,
                    targetCountry: normalizedCountry,
                    targetRelayID: normalizedRelayID?.isEmpty == false ? normalizedRelayID : nil
                )
                try manager.connection.startVPNTunnel()
                self.manager = manager
                self.refreshVPNStatus()
                resolve(nil)
            } catch {
                let message = AppError.message(for: error)
                self.lastError = message
                self.status = .failed
                self.emitStateChanged()
                reject("connect_failed", message, error)
            }
        }
    }

    @objc(disconnect:rejecter:)
    func disconnect(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            self.controlEpoch += 1
            self.manager?.connection.stopVPNTunnel()
            self.refreshVPNStatus()
            resolve(nil)
        }
    }

    @objc(getState:rejecter:)
    func getState(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            resolve(self.statePayload())
        }
    }

    /// Persists the split-tunnel config JSON in the app-group defaults (contract §3). When the
    /// payload actually changed AND both the shared and system lifecycles report a fully connected
    /// tunnel, reapplies it with the same relay-switch dance `connect` uses (stop → 350 ms → start;
    /// providerConfiguration already carries the last targets, so no reconfigure is needed).
    /// Resolves after persistence + reapply dispatch — not reapply completion — matching Android's
    /// ACTION_REAPPLY intent semantics.
    @objc(setSplitTunnelConfig:resolver:rejecter:)
    func setSplitTunnelConfig(
        _ configJson: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            guard let defaults = UserDefaults(suiteName: AppConfig.appGroupIdentifier) else {
                resolve(nil)
                return
            }
            let stored = defaults.string(forKey: AppConfig.splitTunnelConfigDefaultsKey)
            // Persist the raw string always, but only reapply when the EFFECTIVE config changed:
            // a first push of the default disabled config, or any change that nets to the same
            // emitted sing-box config, must never bounce a live tunnel (contract §1). iOS ignores
            // excluded_packages entirely (no OS-level per-app exclusion), so a packages-only change
            // is not an effective change here.
            let effectiveChanged = SplitTunnelConfig.effectiveSignature(ofRawJSON: stored)
                != SplitTunnelConfig.effectiveSignature(ofRawJSON: configJson)
            if stored != configJson {
                defaults.set(configJson, forKey: AppConfig.splitTunnelConfigDefaultsKey)
            }
            if SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: effectiveChanged,
                sharedTunnelIsConnected: self.status == .connected,
                systemTunnelIsConnected: self.vpnStatus == .connected
            ),
               Self.canUseNetworkExtension,
               let manager = self.manager {
                self.controlEpoch += 1
                let reapplyEpoch = self.controlEpoch
                Task { @MainActor in
                    manager.connection.stopVPNTunnel()
                    self.refreshVPNStatus()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // A connect/disconnect during the sleep bumps controlEpoch; if so, that command
                    // now owns the tunnel — don't resurrect it against the user's explicit action.
                    guard self.controlEpoch == reapplyEpoch else {
                        self.refreshVPNStatus()
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        self.lastError = AppError.message(for: error)
                        self.status = .failed
                        self.emitStateChanged()
                        return
                    }
                    self.refreshVPNStatus()
                }
            }
            resolve(nil)
        }
    }

    @objc(getIdentity:rejecter:)
    func getIdentity(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            resolve([
                "clientId": ClientIdentity.getOrCreate(),
                "sessionId": TelemetryManager.activeSession()?.id ?? NSNull(),
            ] as [String: Any])
        }
    }

    // MARK: - Manager plumbing (port of AppViewModel)

    @MainActor
    private func loadExistingManager() async {
        guard Self.canUseNetworkExtension else { return }
        do {
            manager = try await loadOrCreateManager()
            refreshVPNStatus()
        } catch {
            lastError = AppError.message(for: error)
            emitStateChanged()
        }
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
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
        let manager = NETunnelProviderManager()
        manager.localizedDescription = AppConfig.vpnProfileName
        return manager
    }

    private func configure(
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

    // MARK: - State observation

    private func observeVPNStatus() {
        vpnStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshVPNStatus() }
        }
    }

    private func observeSharedState() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let module = Unmanaged<OpenRungVpnModule>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in module.reloadSharedState() }
            },
            AppConfig.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private func reloadSharedState() {
        apply(SharedConnectionState.snapshot())
    }

    @MainActor
    private func refreshVPNStatus() {
        vpnStatus = manager?.connection.status ?? .invalid
        apply(SharedConnectionState.snapshot(), emit: false)
        // If the OS reports the tunnel is fully down but the extension's last write was optimistic
        // (e.g. it was killed without recording a terminal state), reflect disconnected.
        if vpnStatus == .disconnected || vpnStatus == .invalid,
           status == .connected || status == .connecting || status == .preparing {
            status = .disconnected
            relayLabel = nil
        }
        emitStateChanged()
    }

    private func apply(_ snapshot: ConnectionStateSnapshot, emit: Bool = true) {
        status = snapshot.status
        relayLabel = snapshot.relayLabel
        lastError = snapshot.lastError
        logLines = snapshot.logLines
        recentRegions = snapshot.recentRegions
        if emit {
            emitStateChanged()
        }
    }

    // MARK: - Event emission

    private func emitStateChanged() {
        guard hasListeners else { return }
        sendEvent(withName: Self.stateChangedEvent, body: statePayload())
    }

    /// Maps the mirrored `ConnectionStateSnapshot` fields to the contract §3 `NativeVpnState`.
    private func statePayload() -> [String: Any] {
        [
            "status": status.rawValue,
            "relayLabel": relayLabel ?? NSNull(),
            "lastError": lastError ?? NSNull(),
            "logLines": logLines,
            "recents": recentRegions.map { node in
                [
                    "countryCode": node.countryCode,
                    "label": node.label,
                    "latitude": node.latitude,
                    "longitude": node.longitude,
                ] as [String: Any]
            },
        ]
    }

    // MARK: - Helpers

    private static var canUseNetworkExtension: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    private static func normalizedCountryCode(_ countryCode: String?) -> String? {
        guard let normalized = countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              normalized.isEmpty == false
        else {
            return nil
        }
        return normalized
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
