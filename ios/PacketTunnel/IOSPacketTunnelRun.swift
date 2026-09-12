#if canImport(Libbox)
import Foundation
import Libbox
import NetworkExtension

/// Immutable provider ownership per libbox attempt. NE owns the original fd;
/// libbox duplicates it. Close runs after Go joins probes and closes its copy.
final class IOSPacketTunnelRun: NSObject, LibboxOpenRungMobileRunProtocol, @unchecked Sendable {
    private let provider: NEPacketTunnelProvider
    private let settingsCleanup: EngineTunnelSettingsCleanup
    private let lock = NSLock()
    private var ready = false
    private var closed = false
    private lazy var nativePlatform = LibboxPacketTunnelPlatformInterface(tunnelProvider: provider) { [weak self] in
        guard let self else { return }
        self.lock.lock(); self.ready = true; self.lock.unlock()
    }

    init(provider: PacketTunnelProvider) {
        self.provider = provider
        settingsCleanup = provider.settingsCleanup
    }
    func platform() -> (any LibboxPlatformInterfaceProtocol)? { nativePlatform }

    private var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready && !closed }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func waitReady(_ operation: LibboxOpenRungEngineOperation?) throws {
        guard let operation else { throw PacketTunnelEngineError.noOwner }
        while !isReady {
            if operation.isCancelled() || isClosed { throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if operation.isCancelled() { throw CancellationError() }
    }

    func verifyPath(_ operation: LibboxOpenRungEngineOperation?, phase: String?) -> String {
        do {
            guard let operation, isReady else { throw PacketTunnelEngineError.noOwner }
            try EngineOperationRunner.run(cancelled: { operation.isCancelled() || self.isClosed }) { [self] in
                try Task.checkCancellation()
                let probe = PacketTunnelPathProbe(dnsProbe: PacketTunnelDnsProbe(tunnelProvider: provider), httpProbe: try PacketTunnelInternetProbe(tunnelProvider: provider))
                if phase == "startup" { _ = try await probe.verify() }
                else { _ = try await probe.verifyOnce() }
                guard isReady else { throw PacketTunnelEngineError.noOwner }
            }
            return "{\"path\":\"ios_provider_through_tunnel\",\"fresh_dns\":true,\"pinned_https\":true}"
        } catch {
            let result = EngineProbeFailure.result(error, cancelled: operation?.isCancelled() != false, ownsTunnel: isReady)
            return String(decoding: try! JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        }
    }

    func close() throws {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        ready = false
        lock.unlock()
        nativePlatform.reset()
        settingsCleanup.clearAfterRun {
            try EngineOperationRunner.run(cancelled: { false }) { [provider] in
                try await provider.setTunnelNetworkSettings(nil)
            }
        }
    }
}
#endif
