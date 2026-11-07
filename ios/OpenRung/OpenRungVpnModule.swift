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

    private var vpnStatus: NEVPNStatus = .invalid
    private var status: ConnectionStatus = .disconnected
    private var sessionID: String?
    private var relayLabel: String?
    private var relayName: String?
    private var relayClass: String?
    private var lastError: String?
    private var lastErrorCode: String?
    private var logLines: [String] = []
    private var recentRegions: [RecentNode] = []
    private var hasListeners = false
    private var vpnStatusObserver: NSObjectProtocol?
    /// True while a trailing shared-state reload is scheduled (MainActor-confined). Each reload
    /// decodes the full snapshot and serializes an 80-line payload across the bridge, so
    /// notification bursts collapse into one reload ~100 ms later instead of one per line.
    private var sharedStateReloadScheduled = false
    override init() {
        super.init()
        TunnelControl.shared.onActivity = { [weak self] in
            self?.refreshVPNStatus()
        }
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
            guard TunnelControl.canUseNetworkExtension else {
                resolve(false)
                return
            }
            do {
                let loaded = try await TunnelControl.shared.loadOrCreateManager()
                if loaded.manager.protocolConfiguration == nil {
                    try await TunnelControl.shared.configure(
                        manager: loaded.manager,
                        brokerURL: AppConfig.defaultBrokerURL,
                        targetCountry: nil
                    )
                } else {
                    TunnelControl.shared.adopt(loaded.manager)
                }
                TunnelControl.shared.noteProfileSavedIfConfigured()
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
            let shouldSwitchRelay = self.status.isConnected || self.status.isWorking
            do {
                try await TunnelControl.shared.connect(
                    brokerUrl: brokerUrl,
                    targetCountry: targetCountry,
                    targetRelayId: targetRelayId,
                    switchRelay: shouldSwitchRelay
                )
                self.refreshVPNStatus()
                resolve(nil)
            } catch {
                let message = AppError.message(for: error)
                SharedConnectionState.fail(message)
                self.lastError = message
                self.lastErrorCode = nil
                self.status = .failed
                // Relay identity never survives a failure (contract: relayClass/relayName are
                // null whenever not CONNECTED), matching SharedConnectionState.fail().
                self.relayLabel = nil
                self.relayName = nil
                self.relayClass = nil
                self.emitStateChanged()
                reject("connect_failed", message, error)
            }
        }
    }

    @objc(disconnect:rejecter:)
    func disconnect(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            TunnelControl.shared.disconnect()
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
            // a first push of a disabled config, or any change that nets to the same
            // emitted sing-box config, must never bounce a live tunnel (contract §1). iOS ignores
            // excluded_packages entirely (no OS-level per-app exclusion), so a packages-only change
            // is not an effective change here.
            // Both signatures resolve against ONE region read, so a zone change landing between
            // them can never masquerade as a config change (and vice versa). A region change is
            // not this comparison's business anyway: it reaches the engine through the next
            // connect/recovery rebuild, which re-derives from scratch.
            let region = SplitTunnelRegion.deviceRegion
            let effectiveChanged = SplitTunnelConfig.effectiveSignature(ofRawJSON: stored, region: region)
                != SplitTunnelConfig.effectiveSignature(ofRawJSON: configJson, region: region)
            if stored != configJson {
                defaults.set(configJson, forKey: AppConfig.splitTunnelConfigDefaultsKey)
            }
            if SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: effectiveChanged,
                sharedTunnelIsConnected: self.status == .connected,
                systemTunnelIsConnected: self.vpnStatus == .connected
            ),
               TunnelControl.canUseNetworkExtension,
               let manager = TunnelControl.shared.manager {
                let reapplyEpoch = TunnelControl.shared.beginCommand()
                Task { @MainActor in
                    defer { TunnelControl.shared.endCommand(epoch: reapplyEpoch) }
                    manager.connection.stopVPNTunnel()
                    self.refreshVPNStatus()
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    // A connect/disconnect during the sleep bumps controlEpoch; if so, that command
                    // now owns the tunnel — don't resurrect it against the user's explicit action.
                    guard TunnelControl.shared.controlEpoch == reapplyEpoch else {
                        self.refreshVPNStatus()
                        return
                    }
                    do {
                        try manager.connection.startVPNTunnel()
                    } catch {
                        let message = AppError.message(for: error)
                        SharedConnectionState.fail(message)
                        self.lastError = message
                        self.lastErrorCode = nil
                        self.status = .failed
                        // Same failure semantics as the connect() catch above.
                        self.relayLabel = nil
                        self.relayName = nil
                        self.relayClass = nil
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
            self.refreshVPNStatus(emit: false)
            resolve([
                "clientId": ClientIdentity.getOrCreate(),
                "sessionId": self.sessionID ?? NSNull(),
            ] as [String: Any])
        }
    }

    // MARK: - Manager plumbing (port of AppViewModel)

    @MainActor
    private func loadExistingManager() async {
        do {
            try await TunnelControl.shared.loadInstalledManager()
            refreshVPNStatus()
        } catch {
            lastError = AppError.message(for: error)
            lastErrorCode = nil
            emitStateChanged()
        }
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
                Task { @MainActor in module.scheduleSharedStateReload() }
            },
            AppConfig.darwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private func scheduleSharedStateReload() {
        guard !sharedStateReloadScheduled else { return }
        sharedStateReloadScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.sharedStateReloadScheduled = false
            self.reloadSharedState()
        }
    }

    @MainActor
    private func reloadSharedState() {
        // A delayed Darwin notification must not restore a crashed tunnel's identity.
        refreshVPNStatus()
    }

    @MainActor
    private func refreshVPNStatus(emit: Bool = true) {
        vpnStatus = TunnelControl.shared.systemStatus
        var snapshot = SharedConnectionState.snapshot()
        snapshot.reconcileSystemTunnel(isDown: vpnStatus == .disconnected || vpnStatus == .invalid)
        // Only persist once a manager is loaded. Before that, status is `.invalid` and writing
        // the reconciliation would wipe a live tunnel's snapshot on every cold launch.
        if TunnelControl.shared.hasManager {
            SharedConnectionState.persistReconciliation(snapshot)
        }
        apply(snapshot, emit: emit)
    }

    private func apply(_ snapshot: ConnectionStateSnapshot, emit: Bool = true) {
        status = snapshot.status
        sessionID = snapshot.sessionID
        relayLabel = snapshot.relayLabel
        relayName = snapshot.relayName
        relayClass = snapshot.relayClass
        lastError = snapshot.lastError
        lastErrorCode = snapshot.lastErrorCode
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
            "relayName": relayName ?? NSNull(),
            "relayClass": relayClass ?? NSNull(),
            "lastError": lastError ?? NSNull(),
            "lastErrorCode": lastErrorCode ?? NSNull(),
            "logLines": logLines,
            "recents": recentRegions.map { node in
                [
                    "countryCode": node.countryCode,
                    "relayId": node.relayId ?? NSNull(),
                    "label": node.label,
                    "relayName": node.relayName ?? NSNull(),
                    "latitude": node.latitude,
                    "longitude": node.longitude,
                ] as [String: Any]
            },
        ]
    }
}

