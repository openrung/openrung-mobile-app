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

    /// Tunnel (utun/ipsec) and loopback interfaces are not the physical network. They
    /// include this provider's own utun, which setTunnelNetworkSettings reconfigures
    /// whenever a candidate opens its TUN; counting them would make the tunnel's own
    /// bring-up an epoch boundary. Android excludes them by requesting NOT_VPN.
    static let nonPhysicalInterfaceTypes: [NWInterface.InterfaceType] = [.other, .loopback]

    static func physicalInterfaces(_ interfaces: [(name: String, type: NWInterface.InterfaceType, index: Int)]) -> [String] {
        interfaces.filter { !nonPhysicalInterfaceTypes.contains($0.type) }.map { "\($0.name):\($0.type):\($0.index)" }
    }

    static func make(up: Bool, interfaces: [String], supportsDNS: Bool, supportsIPv4: Bool, supportsIPv6: Bool, expensive: Bool, constrained: Bool) -> Self {
        Self(up: up, fingerprint: ([up, supportsDNS, supportsIPv4, supportsIPv6, expensive, constrained].map(String.init) + interfaces.sorted()).joined(separator: "|"))
    }
}

/// Publishes the initial observation AND changed fingerprints. The first path
/// is needed before Start; deduplication does not hide down/up or sleep changes.
/// The monitor evaluates physical interfaces only, so status and capability flags
/// are not derived from the tunnel either.
final class EngineNetworkObserver {
    private let monitor = NWPathMonitor(prohibitedInterfaceTypes: EngineNetworkSnapshot.nonPhysicalInterfaceTypes)
    private let queue = DispatchQueue(label: "com.openrung.app.engine-network")
    private var last: EngineNetworkSnapshot?

    init(receive: @escaping (EngineNetworkSnapshot) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let snapshot = EngineNetworkSnapshot.make(
                up: path.status == .satisfied,
                interfaces: EngineNetworkSnapshot.physicalInterfaces(path.availableInterfaces.map { ($0.name, $0.type, $0.index) }),
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
