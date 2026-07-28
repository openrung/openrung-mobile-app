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
struct NetworkEpochTracker<Value: Equatable & Sendable>: Sendable {
    private(set) var current: Value?

    mutating func absorb(_ value: Value) -> Bool {
        defer { current = value }
        guard let current else { return false }
        return current != value
    }
}

/// A native transport is tied to the physical path on which its outer socket was established. This
/// monitor treats changes to NWPath's visible physical-path fingerprint as epoch boundaries. The
/// first callback establishes a baseline and repeated callbacks for the same fingerprint are
/// ignored. Device wake only resumes the engine; recovery policy remains outside native cores.
final class PhysicalNetworkEpochMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openrung.app.native-network-epoch")
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

    /// A missing initial NWPath callback is not evidence of a physical outage. Only an explicitly
    /// unsatisfied path exempts an adapter loss from the rapid-failure circuit breaker.
    var shouldCountNativeAdapterLoss: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.shouldCountNativeAdapterLoss(physicalPath: tracker.current)
    }

    static func shouldCountNativeAdapterLoss(
        physicalPath: PhysicalNetworkFingerprint?
    ) -> Bool {
        physicalPath?.satisfied != false
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
    /// cancellation. Used only while an active native-transport epoch is being replaced.
    static func waitUntilSatisfied() async throws {
        let stream = AsyncStream<Bool> { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { @Sendable _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.openrung.app.native-network-wait"))
        }
        for await satisfied in stream {
            try Task.checkCancellation()
            if satisfied { return }
        }
        throw CancellationError()
    }
}
