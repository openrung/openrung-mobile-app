import Foundation
import Network

struct PhysicalNetworkFingerprint: Equatable, Sendable {
    let satisfied: Bool
    let interfaces: [String]
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool
    let isExpensive: Bool
    let isConstrained: Bool
}

/// Pure initial-baseline/change detector used by the NWPath adapter and hostless tests.
struct NetworkEpochTracker<Value: Sendable>: Sendable {
    private(set) var current: Value?

    mutating func absorb(_ value: Value) -> Bool {
        defer { current = value }
        // NWPath does not expose route, gateway, DNS-server or Wi-Fi AP identity. Therefore two
        // genuinely different physical paths can have identical visible fingerprints. Absorb only
        // the initial baseline; every later NWPath callback is conservatively a new socket epoch.
        return current != nil
    }
}

/// A WSS connection is tied to the physical path on which its outer socket was established. This
/// monitor treats every post-baseline NWPath callback as an epoch boundary; policy remains in the
/// PacketTunnel provider rather than wsscore.
final class PhysicalNetworkEpochMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openrung.app.wss-network-epoch")
    private let lock = NSLock()
    private var tracker = NetworkEpochTracker<PhysicalNetworkFingerprint>()
    private var stopped = false
    private let onChange: @Sendable (PhysicalNetworkFingerprint) -> Void

    init(onChange: @escaping @Sendable (PhysicalNetworkFingerprint) -> Void) {
        self.onChange = onChange
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: queue)
    }

    var isSatisfied: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracker.current?.satisfied ?? false
    }

    func close() {
        lock.lock()
        guard stopped == false else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        monitor.pathUpdateHandler = nil
        monitor.cancel()
    }

    private func update(_ path: NWPath) {
        let fingerprint = Self.fingerprint(path)
        lock.lock()
        let changed = stopped == false && tracker.absorb(fingerprint)
        lock.unlock()
        if changed { onChange(fingerprint) }
    }

    private static func fingerprint(_ path: NWPath) -> PhysicalNetworkFingerprint {
        PhysicalNetworkFingerprint(
            satisfied: path.status == .satisfied,
            interfaces: path.availableInterfaces.map { "\($0.name):\($0.type):\($0.index)" }.sorted(),
            supportsDNS: path.supportsDNS,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
}

enum PhysicalNetworkAvailability {
    /// Waits without a polling timer and tears the temporary NWPath monitor down on success or task
    /// cancellation. Used only while an active WSS epoch is being replaced.
    static func waitUntilSatisfied() async throws {
        let stream = AsyncStream<Bool> { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { @Sendable _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.openrung.app.wss-network-wait"))
        }
        for await satisfied in stream {
            try Task.checkCancellation()
            if satisfied { return }
        }
        throw CancellationError()
    }
}
