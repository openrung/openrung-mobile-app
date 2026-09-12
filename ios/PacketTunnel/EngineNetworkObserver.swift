import Foundation
import Network

/// A dormant on-demand/cellular path can be activated by an outbound dial.
/// It is not yet an observed-up path, but libbox must retain its interfaces.
enum EngineInterfaceAvailability {
    static func canDial(_ status: NWPath.Status) -> Bool { status != .unsatisfied }
}

struct EngineNetworkSnapshot: Equatable {
    let up: Bool
    let fingerprint: String

    static func make(up: Bool, interfaces: [String], supportsDNS: Bool, supportsIPv4: Bool, supportsIPv6: Bool, expensive: Bool, constrained: Bool) -> Self {
        Self(up: up, fingerprint: ([up, supportsDNS, supportsIPv4, supportsIPv6, expensive, constrained].map(String.init) + interfaces.sorted()).joined(separator: "|"))
    }
}

/// Publishes the initial observation AND changed fingerprints. The first path
/// is needed before Start; deduplication does not hide down/up or sleep changes.
final class EngineNetworkObserver {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.openrung.app.engine-network")
    private var last: EngineNetworkSnapshot?

    init(receive: @escaping (EngineNetworkSnapshot) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = EngineNetworkSnapshot.make(
                up: path.status == .satisfied,
                interfaces: path.availableInterfaces.map { "\($0.name):\($0.type):\($0.index)" },
                supportsDNS: path.supportsDNS, supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6,
                expensive: path.isExpensive, constrained: path.isConstrained)
            guard snapshot != self.last else { return }
            self.last = snapshot
            receive(snapshot)
        }
        monitor.start(queue: queue)
    }

    func close() { monitor.cancel() }
    deinit { monitor.cancel() }
}
