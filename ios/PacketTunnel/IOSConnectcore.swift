import Foundation
#if canImport(Libbox)
import Libbox
#endif

enum IOSConnectcore {
    static let host = PacketTunnelEngineHost(diagnostic: SharedConnectionState.appendLog) { events in
        #if canImport(Libbox)
        return try NativePacketTunnelEngine(events: events)
        #else
        throw PacketTunnelEngineError.unavailable
        #endif
    }
}

#if canImport(Libbox)
private final class NativePacketTunnelEngine: PacketTunnelEngine {
    private let native: any LibboxOpenRungEngineProtocol
    private let listener: NativeEngineListener
    private let mobileHost = NativeMobileHost()

    init(events: EngineEventDispatcher) throws {
        listener = NativeEngineListener(events)
        let directories = try EngineDirectories.make()
        let setup = LibboxSetupOptions()
        setup.basePath = directories.base.path
        setup.workingPath = directories.working.path
        setup.tempPath = directories.temporary.path
        #if DEBUG
        setup.logMaxLines = 3000
        setup.debug = true
        #else
        setup.logMaxLines = 300
        setup.debug = false
        #endif
        setup.crashReportSource = AppConfig.engineDirectoryName
        setup.oomKillerEnabled = false
        setup.oomKillerDisabled = true
        // The Go runtime calls CommandServer directly; no loopback gRPC listener.
        var error: NSError?
        guard LibboxSetup(setup, &error) else { throw error ?? PacketTunnelEngineError.unavailable as NSError }
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier) else {
            throw PacketTunnelEngineError.noOwner
        }
        let config: [String: Any] = [
            "install_id": ClientIdentity.getOrCreate(),
            "app_version": DeviceAttributes.appVersion,
            "platform_version": DeviceAttributes.osVersion,
            "telemetry_directory": directory.path,
            "punch_coordinator_cert_sha256_by_host": AppConfig.punchCoordinatorCertificateSHA256ByHost,
        ]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        guard let engine = LibboxNewOpenRungMobileEngineForIOS(json, mobileHost, listener, &error) else {
            throw error ?? PacketTunnelEngineError.unavailable as NSError
        }
        native = engine
    }

    func start(broker: String, country: String, relay: String) throws { try native.start(broker, country: country, relayID: relay) }
    func stop() throws { try native.stop(5_000) }
    var teardownComplete: Bool { native.teardownComplete() }
    func pause() { native.pause() }
    func resume() { native.resume() }
    func networkChanged(_ snapshot: EngineNetworkSnapshot) throws {
        // Apple owns physical DNS resolution for provider sockets; unlike Android
        // there is no protected resolver requiring a separately enumerated DNS list.
        try native.networkChanged(snapshot.up, fingerprint: snapshot.fingerprint, dnsServersJSON: "[]")
    }
}

private final class NativeEngineListener: NSObject, LibboxOpenRungEngineListenerProtocol {
    private let events: EngineEventDispatcher
    init(_ events: EngineEventDispatcher) { self.events = events }
    func onEvent(_ raw: String?) { events.onEvent(raw) }
}

private final class NativeMobileHost: NSObject, LibboxOpenRungMobileHostProtocol {
    private func provider() throws -> PacketTunnelProvider {
        guard let owner = IOSConnectcore.host.currentOwner() as? PacketTunnelProvider else { throw PacketTunnelEngineError.noOwner }
        return owner
    }
    func settingsJSON(_ error: NSErrorPointer) -> String {
        do { return try provider().settingsJSON() }
        catch let failure { error?.pointee = failure as NSError; return "" }
    }
    func attributesJSON() -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: DeviceAttributes.current()), as: UTF8.self)) ?? "{}"
    }
    func newRun(_ telemetry: LibboxOpenRungRunTelemetry?) throws -> any LibboxOpenRungMobileRunProtocol {
        // iOS does not attribute applications. Go owns final aggregate traffic.
        IOSPacketTunnelRun(provider: try provider())
    }
}
#endif
