import Foundation

/// During stopTunnel, NetworkExtension withdraws settings and may reject further
/// settings requests. After libbox closes, settings removal is best effort:
/// rejection does not mean its duplicated TUN fd is still alive. Every new
/// candidate must apply fresh settings before it can become ready. The lock
/// guards the OS-stop handoff without being held across NE calls.
final class EngineTunnelSettingsCleanup {
    private let lock = NSLock()
    private var osStopping = false
    private let diagnostic: (String) -> Void

    init(diagnostic: @escaping (String) -> Void = { _ in }) { self.diagnostic = diagnostic }

    func beginProviderStart() { lock.lock(); osStopping = false; lock.unlock() }
    func beginProviderStop() { lock.lock(); osStopping = true; lock.unlock() }
    private var handledByOS: Bool { lock.lock(); defer { lock.unlock() }; return osStopping }

    func clearAfterRun(_ clear: () throws -> Void) {
        guard !handledByOS else { return }
        do { try clear() }
        catch { diagnostic("Unable to clear retired tunnel settings: \(error.localizedDescription)") }
    }
}

/// Only OS-owned inputs cross this boundary; Go supplies all relay credentials,
/// bridge endpoints, DNS chains and configuration preflight.
enum EngineTunnelSettings {
    static func json(rules: SplitTunnelRules?, debug: Bool = _isDebugAssertConfiguration()) throws -> String {
        var input: [String: Any] = [
            "tunnel_ipv4_address": SingBoxConfiguration.defaultTunnelIPv4Address,
            "tunnel_ipv6_address": "fdfe:dcba:9876::1/126",
            "mtu": 1400,
            "log_level": debug ? "info" : "warn",
            "probe_domain_suffixes": ProbeTargets.ruleDomainSuffixes,
        ]
        if let rules {
            input["split_tunnel"] = ["bypass_lan": rules.bypassLan, "bypass_countries": rules.bypassCountries, "rule_set_directory": rules.ruleSetDirectory] as [String: Any]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
    }
}
