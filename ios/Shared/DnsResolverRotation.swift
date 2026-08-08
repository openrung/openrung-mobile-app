import Foundation

/// App-level DNS resolver failover. sing-box has no upstream failover of its own — `dns.final`
/// names exactly one server — so the provider rotates which DoH resolver is emitted first
/// (`dns-0`, the final/default resolver) whenever a fresh-DNS probe shows the current primary
/// cannot answer through the tunnel. Every `SingBoxConfiguration` built afterwards, including
/// same-relay retries, WSS-ladder attempts, and recovery reconnects, picks up the rotated
/// order. Mirrors Android `DnsResolverRotation`.
public final class DnsResolverRotation: @unchecked Sendable {
    /// DoH-capable public resolvers reached as IP literals: no bootstrap resolution needed.
    public static let defaultResolvers = ["1.1.1.1", "8.8.8.8"]

    private let resolvers: [String]
    private let lock = NSLock()
    private var offset = 0

    public init(resolvers: [String] = DnsResolverRotation.defaultResolvers) {
        precondition(resolvers.isEmpty == false, "at least one DNS resolver is required")
        self.resolvers = resolvers
    }

    public var resolverCount: Int { resolvers.count }

    /// Resolver IPs in emission order; index 0 becomes the `dns-0` final resolver.
    public func currentServers() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return rotated(by: offset)
    }

    /// Advances the rotation only when `failedServers` is still the current order, so repeated
    /// reports of the same dead primary (startup retry + health-loop strikes) advance exactly
    /// once and a stale report can never skip past a resolver that has not been tried. Returns
    /// true when this call performed the advance.
    @discardableResult
    public func noteDnsPathFailure(_ failedServers: [String]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard rotated(by: offset) == failedServers else { return false }
        offset += 1
        return true
    }

    private func rotated(by offset: Int) -> [String] {
        let shift = ((offset % resolvers.count) + resolvers.count) % resolvers.count
        return (0..<resolvers.count).map { resolvers[($0 + shift) % resolvers.count] }
    }
}
