import Foundation
import Network
import NetworkExtension
import OSLog

protocol PacketTunnelProxyEngine: AnyObject {
    func start(relay: RelayDescriptor, tunnelProvider: NEPacketTunnelProvider) async throws
    func stop()
    /// Pause the engine when the device sleeps and resume it on wake, so iOS doesn't terminate the
    /// extension for CPU/wakeups while the tunnel sits idle. Safe no-op before the engine starts.
    func pause()
    func wake()
}

#if canImport(Libbox)
import Libbox

final class EmbeddedProxyEngine: PacketTunnelProxyEngine {
    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "EmbeddedProxyEngine")
    private var commandServer: LibboxCommandServer?
    private var platformInterface: LibboxPacketTunnelPlatformInterface?
    private var activeRelay: RelayDescriptor?

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
        // The libbox command server listens on loopback TCP. iOS has no per-app loopback isolation,
        // and the unix-socket alternative (commandServerListenPort = 0) puts the socket at
        // basePath/command.sock, whose path overflows Darwin's 104-byte sun_path limit inside an
        // app-extension container. So gate the listener with a random per-launch secret: libbox's
        // gRPC auth interceptor rejects any client that doesn't present it, which blocks a
        // co-installed app from issuing commands (close/reload the service, subscribe to logs,
        // trigger a crash). The app's own control calls (startOrReloadService, closeService, pause,
        // wake) are direct in-process method calls and bypass the interceptor.
        setupOptions.commandServerListenPort = try availableCommandServerPort()
        setupOptions.commandServerSecret = Self.makeCommandServerSecret()

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
        logger.info("libbox started for relay \(relay.id, privacy: .public)")
    }

    func stop() {
        try? commandServer?.closeService()
        commandServer?.close()
        platformInterface?.reset()
        commandServer = nil
        platformInterface = nil
        activeRelay = nil
    }

    func pause() {
        commandServer?.pause()
    }

    func wake() {
        commandServer?.wake()
    }

    /// Per-launch random secret for the command server's gRPC auth interceptor (see `start`).
    private static func makeCommandServerSecret() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
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

    func pause() {}
    func wake() {}
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
