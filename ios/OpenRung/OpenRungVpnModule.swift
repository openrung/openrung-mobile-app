import Foundation
import NetworkExtension
import React

/// React Native bridge for the OpenRung VPN (contract §3). Port of the manager/state half of the
/// production `AppViewModel`: owns the `NETunnelProviderManager` (found by localizedDescription
/// "OpenRung Volunteer VPN"), mirrors the rich connection state the PacketTunnel extension
/// publishes via `SharedConnectionState` (re-read on a Darwin notification), watches
/// `.NEVPNStatusDidChange`, and reports every change to JS as an `openrungStateChanged` event.
@objc(OpenRungVpn)
final class OpenRungVpnModule: RCTEventEmitter {
    private static let stateChangedEvent = "openrungStateChanged"
    private static let trafficChangedEvent = "openrungTrafficChanged"

    private var manager: NETunnelProviderManager?
    private var vpnStatus: NEVPNStatus = .invalid
    private var status: ConnectionStatus = .disconnected
    private var relayLabel: String?
    private var lastError: String?
    private var logLines: [String] = []
    private var recentRegions: [RecentNode] = []
    private var hasListeners = false
    private var vpnStatusObserver: NSObjectProtocol?
    private var hadTraffic = false

    override init() {
        super.init()
        // What the app shows on a cold launch: a stale CONNECTED never survives, and the relay
        // label (which could leak a prior relay) is dropped until re-resolved.
        apply(SharedConnectionState.sanitizedForColdStart(), emit: false)
        observeVPNStatus()
        observeSharedState()
        observeTrafficState()
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

    override func supportedEvents() -> [String]! { [Self.stateChangedEvent, Self.trafficChangedEvent] }

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
    @objc(connect:targetCountry:resolver:rejecter:)
    func connect(
        _ brokerUrl: String,
        targetCountry: String?,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        Task { @MainActor in
            let normalizedCountry = Self.normalizedCountryCode(targetCountry)
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
                try await self.configure(manager: manager, brokerURL: brokerURL, targetCountry: normalizedCountry)
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

    @objc(getIdentity:rejecter:)
    func getIdentity(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            resolve([
                "clientId": ClientIdentity.getOrCreate(),
                "sessionId": TelemetryManager.activeSession()?.id ?? NSNull(),
            ] as [String: Any])
        }
    }

    @objc(getTrafficStats:rejecter:)
    func getTrafficStats(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        Task { @MainActor in
            if let snapshot = SharedTrafficState.snapshot() {
                resolve(Self.trafficPayload(snapshot))
            } else {
                resolve(NSNull())
            }
        }
    }

    @objc(measureLatency:timeoutMs:resolver:rejecter:)
    func measureLatency(
        _ targets: NSArray,
        timeoutMs: NSNumber,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        let parsed: [LatencyProbeTarget] = targets.compactMap { entry in
            guard let dict = entry as? [String: Any],
                  let id = dict["id"] as? String,
                  let host = dict["host"] as? String,
                  let port = dict["port"] as? Int
            else { return nil }
            return LatencyProbeTarget(id: id, host: host, port: port)
        }
        // Probes ride the tunnel whenever it's up (no app-side protect() on iOS).
        let viaTunnel = status.isConnected || status.isWorking
        Task {
            let measurement = await LatencyProber.measure(
                targets: parsed,
                timeoutMillis: timeoutMs.intValue,
                viaTunnel: viaTunnel
            )
            let results = measurement.results.map { result -> [String: Any] in
                [
                    "id": result.id,
                    "latencyMs": result.latencyMs.map { NSNumber(value: $0) } ?? NSNull(),
                    "reachable": result.reachable,
                ]
            }
            resolve(["viaTunnel": measurement.viaTunnel, "results": results] as [String: Any])
        }
    }

    // Per-app split tunneling is Android-only (iOS per-app VPN is MDM-managed). These inert
    // implementations keep the JS contract uniform so the TS side can gate on Platform.OS.

    @objc(getInstalledApps:rejecter:)
    func getInstalledApps(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve([])
    }

    @objc(getSplitTunnelConfig:rejecter:)
    func getSplitTunnelConfig(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        resolve(["mode": "off", "packages": []] as [String: Any])
    }

    @objc(setSplitTunnelConfig:resolver:rejecter:)
    func setSplitTunnelConfig(
        _ config: NSDictionary,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolve(["needsReconnect": false])
    }

    @objc(getPersistedLog:rejecter:)
    func getPersistedLog(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.global(qos: .utility).async {
            resolve(RuntimeLogStore.readLines())
        }
    }

    @objc(clearPersistedLog:rejecter:)
    func clearPersistedLog(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        DispatchQueue.global(qos: .utility).async {
            RuntimeLogStore.clear()
            resolve(nil)
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
        if let existing = managers.first(where: { $0.localizedDescription == AppConfig.vpnProfileName }) {
            return existing
        }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = AppConfig.vpnProfileName
        return manager
    }

    private func configure(manager: NETunnelProviderManager, brokerURL: URL, targetCountry: String?) async throws {
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = AppConfig.packetTunnelBundleIdentifier
        tunnelProtocol.serverAddress = brokerURL.host ?? brokerURL.absoluteString
        var providerConfiguration = [AppConfig.providerBrokerURLKey: brokerURL.absoluteString]
        if let targetCountry {
            providerConfiguration[AppConfig.providerTargetCountryKey] = targetCountry
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

    private func observeTrafficState() {
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let module = Unmanaged<OpenRungVpnModule>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in module.reloadTrafficState() }
            },
            AppConfig.trafficDarwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    @MainActor
    private func reloadSharedState() {
        apply(SharedConnectionState.snapshot())
    }

    /// Contract: samples while connected + ONE zeroed emission when the extension clears the
    /// shared sample, so the JS side resets without special-casing.
    @MainActor
    private func reloadTrafficState() {
        guard hasListeners else { return }
        if let snapshot = SharedTrafficState.snapshot() {
            hadTraffic = true
            sendEvent(withName: Self.trafficChangedEvent, body: Self.trafficPayload(snapshot))
        } else if hadTraffic {
            hadTraffic = false
            sendEvent(withName: Self.trafficChangedEvent, body: Self.zeroTrafficPayload())
        }
    }

    private static func trafficPayload(_ snapshot: TrafficSnapshot) -> [String: Any] {
        [
            "upBps": snapshot.upBps,
            "downBps": snapshot.downBps,
            "upTotalBytes": snapshot.upTotalBytes,
            "downTotalBytes": snapshot.downTotalBytes,
            "updatedAtMs": snapshot.updatedAtMs,
        ]
    }

    private static func zeroTrafficPayload() -> [String: Any] {
        [
            "upBps": 0,
            "downBps": 0,
            "upTotalBytes": 0,
            "downTotalBytes": 0,
            "updatedAtMs": Int64(Date().timeIntervalSince1970 * 1000),
        ]
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
