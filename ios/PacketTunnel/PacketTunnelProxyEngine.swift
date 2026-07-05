import Foundation
import Network
import NetworkExtension
import OSLog

protocol PacketTunnelProxyEngine: AnyObject {
    func start(relay: RelayDescriptor, tunnelProvider: NEPacketTunnelProvider) async throws
    func stop()
}

#if canImport(Libbox)
import Libbox

final class EmbeddedProxyEngine: PacketTunnelProxyEngine {
    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "EmbeddedProxyEngine")
    private var commandServer: LibboxCommandServer?
    private var platformInterface: LibboxPacketTunnelPlatformInterface?
    private var activeRelay: RelayDescriptor?
    private var trafficClient: LibboxCommandClient?
    private var trafficHandler: TrafficStatusHandler?

    func start(relay: RelayDescriptor, tunnelProvider: NEPacketTunnelProvider) async throws {
        activeRelay = relay

        let configuration = try SingBoxConfiguration(relay: relay).encodedJSONString()
        let directories = try EngineDirectories.make()
        TunnelDiagnostics.recordEvent("Generated sing-box config and engine directories")
        logger.info("Generated sing-box config and engine directories")

        let setupOptions = LibboxSetupOptions()
        setupOptions.basePath = directories.base.path
        setupOptions.workingPath = directories.working.path
        setupOptions.tempPath = directories.temporary.path
        setupOptions.logMaxLines = 3000
        setupOptions.debug = true
        setupOptions.crashReportSource = AppConfig.engineDirectoryName
        setupOptions.oomKillerEnabled = false
        setupOptions.oomKillerDisabled = true
        setupOptions.commandServerListenPort = try availableCommandServerPort()

        TunnelDiagnostics.recordEvent("Setting up libbox")
        logger.info("Setting up libbox")
        var setupError: NSError?
        LibboxSetup(setupOptions, &setupError)
        if let setupError {
            throw PacketTunnelProxyEngineError.engineStartFailed(setupError.localizedDescription)
        }

        let platformInterface = LibboxPacketTunnelPlatformInterface(tunnelProvider: tunnelProvider)
        var commandServerError: NSError?
        guard let commandServer = LibboxNewCommandServer(platformInterface, platformInterface, &commandServerError) else {
            throw PacketTunnelProxyEngineError.engineStartFailed(commandServerError?.localizedDescription ?? "Unable to create libbox command server.")
        }

        do {
            TunnelDiagnostics.recordEvent("Starting libbox command server")
            logger.info("Starting libbox command server")
            try commandServer.start()
            TunnelDiagnostics.recordEvent("Starting libbox service")
            logger.info("Starting libbox service")
            try commandServer.startOrReloadService(configuration, options: LibboxOverrideOptions())
        } catch {
            commandServer.close()
            throw PacketTunnelProxyEngineError.engineStartFailed(error.localizedDescription)
        }

        self.platformInterface = platformInterface
        self.commandServer = commandServer
        startTrafficMonitor()
        logger.info("libbox started for relay \(relay.id, privacy: .public)")
    }

    func stop() {
        stopTrafficMonitor()
        try? commandServer?.closeService()
        commandServer?.close()
        platformInterface?.reset()
        commandServer = nil
        platformInterface = nil
        activeRelay = nil
    }

    /// Attaches an in-process CommandStatus client to the command server started above (it
    /// dials the LibboxSetup command-server port): samples arrive every ~2s and are published
    /// to the host app via `SharedTrafficState`. The 1s pre-connect delay lets the server
    /// finish binding.
    private func startTrafficMonitor() {
        stopTrafficMonitor()
        let handler = TrafficStatusHandler()
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.statusInterval = 2_000_000_000
        guard let client = LibboxNewCommandClient(handler, options) else {
            logger.warning("could not create the traffic status client")
            return
        }
        trafficHandler = handler
        trafficClient = client
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self, logger] in
            guard let self, self.trafficClient === client else { return }
            do {
                try client.connect()
            } catch {
                logger.warning("traffic status client failed to connect: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func stopTrafficMonitor() {
        try? trafficClient?.disconnect()
        trafficClient = nil
        trafficHandler = nil
        SharedTrafficState.clear()
    }

    private func availableCommandServerPort() throws -> Int32 {
        var port: Int32 = 0
        var error: NSError?
        guard LibboxAvailablePort(19090, &port, &error) else {
            throw PacketTunnelProxyEngineError.engineStartFailed(error?.localizedDescription ?? "Unable to allocate libbox command server port.")
        }
        TunnelDiagnostics.recordEvent("Using libbox command server port \(port)")
        logger.info("Using libbox command server port \(port, privacy: .public)")
        return port
    }
}

/// CommandStatus stream handler: converts total byte counters into rate + total samples
/// (rates derived against locally measured elapsed time, so they stay correct even if the
/// stream interval drifts). All other stream callbacks are unused no-ops.
private final class TrafficStatusHandler: NSObject, LibboxCommandClientHandlerProtocol {
    private var lastUplinkTotal: Int64 = -1
    private var lastDownlinkTotal: Int64 = -1
    private var lastSampleUptime: TimeInterval = 0

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message, message.trafficAvailable else { return }
        let nowUptime = ProcessInfo.processInfo.systemUptime
        let elapsedMs = Int64((nowUptime - lastSampleUptime) * 1000)
        let hasPrevious = lastUplinkTotal >= 0 && elapsedMs >= 1 && elapsedMs <= 60_000
        let upBps = hasPrevious ? max(0, (message.uplinkTotal - lastUplinkTotal) * 1000 / elapsedMs) : 0
        let downBps = hasPrevious ? max(0, (message.downlinkTotal - lastDownlinkTotal) * 1000 / elapsedMs) : 0
        lastUplinkTotal = message.uplinkTotal
        lastDownlinkTotal = message.downlinkTotal
        lastSampleUptime = nowUptime
        SharedTrafficState.write(
            TrafficSnapshot(
                upBps: upBps,
                downBps: downBps,
                upTotalBytes: message.uplinkTotal,
                downTotalBytes: message.downlinkTotal,
                updatedAtMs: Int64(Date().timeIntervalSince1970 * 1000)
            )
        )
    }

    func clearLogs() {}
    func connected() {}
    func disconnected(_ message: String?) {}
    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}
    func setDefaultLogLevel(_ level: Int32) {}
    func updateClashMode(_ newMode: String?) {}
    // Swift importer renames writeConnectionEvents: (its noun matches the arg type) to write(_:).
    func write(_ events: LibboxConnectionEvents?) {}
    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}
    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}
    func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {}
}

#else

final class EmbeddedProxyEngine: PacketTunnelProxyEngine {
    private var activeRelay: RelayDescriptor?

    func start(relay: RelayDescriptor, tunnelProvider _: NEPacketTunnelProvider) async throws {
        activeRelay = relay
        _ = try SingBoxConfiguration(relay: relay).encodedJSON()

        throw PacketTunnelProxyEngineError.engineNotLinked
    }

    func stop() {
        activeRelay = nil
    }
}

#endif

enum PacketTunnelProxyEngineError: LocalizedError {
    case engineNotLinked
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineNotLinked:
            return "Libbox.xcframework is not linked yet. Build sing-box lib_apple and add Libbox to the PacketTunnel target."
        case .engineStartFailed(let message):
            return "The embedded VLESS Reality Vision engine failed to start: \(message)"
        }
    }
}
