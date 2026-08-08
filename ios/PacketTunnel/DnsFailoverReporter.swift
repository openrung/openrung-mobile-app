import Foundation

/// Owns the DoH resolver rotation plus the order the RUNNING engine was verified with, and
/// reports a failover exactly once per failed order.
///
/// Freezing the active order matters: the health loop observes failures from an engine that was
/// started earlier, and a rotation may already have happened (startup retry, another epoch). If
/// failures were reported against the CURRENT order, three health-loop strikes could advance the
/// rotation three times and skip past resolvers that were never tried. Reporting against the
/// frozen order makes `DnsResolverRotation`'s compare-and-advance a no-op for every strike after
/// the first, so the recovery reconnect leads with exactly the next untried resolver.
/// Port of Android `DnsFailoverReporter`.
final class DnsFailoverReporter: @unchecked Sendable {
    private let rotation: DnsResolverRotation
    private let onFailover: (String, String) -> Void
    private let lock = NSLock()
    private var activeServers = DnsResolverRotation.defaultResolvers

    init(
        rotation: DnsResolverRotation = DnsResolverRotation(),
        onFailover: @escaping (String, String) -> Void
    ) {
        self.rotation = rotation
        self.onFailover = onFailover
    }

    /// Resolver order for the next configuration build.
    func currentServers() -> [String] { rotation.currentServers() }

    var resolverCount: Int { rotation.resolverCount }

    /// Freezes the order the now-running engine was verified with.
    func activate(_ servers: [String]) {
        lock.lock()
        activeServers = servers
        lock.unlock()
    }

    /// Reports a DNS-path failure of `servers` (defaults to the frozen active order, which is
    /// what the health loop must use). Returns true when the rotation actually advanced, i.e.
    /// when this was the first report of that order.
    @discardableResult
    func reportFailure(_ servers: [String]? = nil) -> Bool {
        lock.lock()
        let failed = servers ?? activeServers
        lock.unlock()
        guard rotation.noteDnsPathFailure(failed) else { return false }
        onFailover(failed.first ?? "", rotation.currentServers().first ?? "")
        return true
    }
}
