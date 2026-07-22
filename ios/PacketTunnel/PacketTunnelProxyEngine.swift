import Foundation
import Network
import NetworkExtension
import OSLog

protocol PacketTunnelProxyEngine: AnyObject {
    func start(
        relay: RelayDescriptor,
        configuration: SingBoxConfiguration,
        tunnelProvider: NEPacketTunnelProvider
    ) async throws
    func stop()
    /// Pause the engine when the device sleeps and resume it on wake, so iOS doesn't terminate the
    /// extension for CPU/wakeups while the tunnel sits idle. Safe no-op before the engine starts.
    func pause()
    func wake()
    /// Completes only when libbox asks the extension to stop unexpectedly. An intentional `stop()`
    /// finishes the waiter without reporting a failure.
    func waitForUnexpectedStop() async -> String?
    var hasUnexpectedStop: Bool { get }
}

private final class EngineStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<String>.Continuation
    let events: AsyncStream<String>
    private var unexpectedReason: String?
    private var finished = false

    init() {
        var captured: AsyncStream<String>.Continuation?
        events = AsyncStream { captured = $0 }
        continuation = captured!
    }

    var hasUnexpectedStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedReason != nil
    }

    func reportUnexpected(_ reason: String) {
        lock.lock()
        guard finished == false else {
            lock.unlock()
            return
        }
        unexpectedReason = reason
        finished = true
        lock.unlock()
        continuation.yield(reason)
        continuation.finish()
    }

    func finishExpected() {
        lock.lock()
        guard finished == false else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.finish()
    }

    func wait() async -> String? {
        for await reason in events { return reason }
        return nil
    }
}

#if canImport(Libbox)
import Libbox

final class EmbeddedProxyEngine: PacketTunnelProxyEngine {
    private let logger = Logger(subsystem: AppConfig.loggingSubsystem, category: "EmbeddedProxyEngine")
    private var commandServer: LibboxCommandServer?
    private var statusClient: LibboxCommandClient?
    private var platformInterface: LibboxPacketTunnelPlatformInterface?
    private var activeRelay: RelayDescriptor?
    private let stopSignal = EngineStopSignal()

    /// Status push interval, a Go time.Duration in nanoseconds.
    private static let statusIntervalNs: Int64 = 3_000_000_000

    /// Performs every deterministic local check available before opening a relay socket. This is
    /// intentionally ahead of direct reachability so a missing/stale native engine, unwritable
    /// extension storage, or invalid sing-box configuration cannot mint a WSS ticket merely because
    /// the remote TCP path also happens to be blocked.
    static func preflight(configuration: SingBoxConfiguration) throws {
        let configurationJSON = try configuration.encodedJSONString()
        _ = try EngineDirectories.make()
        var validationError: NSError?
        guard LibboxCheckConfig(configurationJSON, &validationError) else {
            throw PacketTunnelProxyEngineError.engineStartFailed(
                validationError?.localizedDescription ?? "Invalid sing-box configuration."
            )
        }
    }

    func start(
        relay: RelayDescriptor,
        configuration: SingBoxConfiguration,
        tunnelProvider: NEPacketTunnelProvider
    ) async throws {
        activeRelay = relay

        let configurationJSON = try configuration.encodedJSONString()
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

        let platformInterface = LibboxPacketTunnelPlatformInterface(
            tunnelProvider: tunnelProvider,
            onUnexpectedServiceStop: { [stopSignal] in
                stopSignal.reportUnexpected("libbox service stopped unexpectedly")
            }
        )
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
            try commandServer.startOrReloadService(configurationJSON, options: LibboxOverrideOptions())
        } catch {
            commandServer.close()
            throw PacketTunnelProxyEngineError.engineStartFailed(error.localizedDescription)
        }

        self.platformInterface = platformInterface
        self.commandServer = commandServer
        statusClient = connectStatusClient()
        logger.info("libbox started for relay \(relay.id, privacy: .public)")
    }

    /// Subscribes to the in-process libbox status stream, whose messages carry the tunnel's
    /// cumulative uplink/downlink byte counters (enabled by the clash_api traffic accounting in
    /// the sing-box config). Best-effort: if the subscription fails, sessions simply omit the
    /// bytes_sent/bytes_received telemetry measurements.
    private func connectStatusClient() -> LibboxCommandClient? {
        let options = LibboxCommandClientOptions()
        options.addCommand(LibboxCommandStatus)
        options.statusInterval = Self.statusIntervalNs
        guard let client = LibboxNewCommandClient(TrafficStatusHandler(), options) else {
            logger.warning("Unable to create libbox status client; session traffic will not be reported")
            return nil
        }
        do {
            try client.connect()
        } catch {
            logger.warning("libbox status client connect failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return client
    }

    func stop() {
        stopSignal.finishExpected()
        try? statusClient?.disconnect()
        statusClient = nil
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

    func waitForUnexpectedStop() async -> String? {
        await stopSignal.wait()
    }

    var hasUnexpectedStop: Bool { stopSignal.hasUnexpectedStop }

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

/// Receives libbox status pushes and forwards the tunnel's traffic counters to telemetry.
private final class TrafficStatusHandler: NSObject, LibboxCommandClientHandlerProtocol {
    func connected() {}

    func disconnected(_ message: String?) {}

    func clearLogs() {}

    func initializeClashMode(_ modeList: (any LibboxStringIteratorProtocol)?, currentMode: String?) {}

    func setDefaultLogLevel(_ level: Int32) {}

    func updateClashMode(_ newMode: String?) {}

    /// Deliberately dropped: per-flow connection events would pair the client with every
    /// destination visited, and the broker keeps only an hourly per-application count of
    /// `application_connection` events. If iOS ever reports application usage, aggregate
    /// client-side like Android's `TelemetryManager.recordApplicationConnection` (skip DNS,
    /// one event per app per window, no destination fields).
    func write(_ events: LibboxConnectionEvents?) {}

    func writeGroups(_ message: (any LibboxOutboundGroupIteratorProtocol)?) {}

    func writeLogs(_ messageList: (any LibboxLogIteratorProtocol)?) {}

    func writeOutbounds(_ message: (any LibboxOutboundGroupItemIteratorProtocol)?) {}

    func writeStatus(_ message: LibboxStatusMessage?) {
        guard let message, message.trafficAvailable else { return }
        TelemetryManager.updateTrafficCounters(
            bytesSent: message.uplinkTotal,
            bytesReceived: message.downlinkTotal
        )
    }
}

#else

final class EmbeddedProxyEngine: PacketTunnelProxyEngine {
    private var activeRelay: RelayDescriptor?
    private let stopSignal = EngineStopSignal()

    static func preflight(configuration: SingBoxConfiguration) throws {
        _ = try configuration.encodedJSON()
        throw PacketTunnelProxyEngineError.engineNotLinked
    }

    func start(
        relay: RelayDescriptor,
        configuration: SingBoxConfiguration,
        tunnelProvider _: NEPacketTunnelProvider
    ) async throws {
        activeRelay = relay
        _ = try configuration.encodedJSON()

        throw PacketTunnelProxyEngineError.engineNotLinked
    }

    func stop() {
        stopSignal.finishExpected()
        activeRelay = nil
    }

    func pause() {}
    func wake() {}
    func waitForUnexpectedStop() async -> String? { await stopSignal.wait() }
    var hasUnexpectedStop: Bool { stopSignal.hasUnexpectedStop }
}

#endif

// PacketTunnelProxyEngineError moved to PacketTunnelProxyEngineError.swift so FailureClassifier and
// its tests can depend on it without linking Libbox.
