import Foundation
#if canImport(Libbox)
import Libbox
#endif

/// Platform input assembly for the shared sing-box config builder: gathers the iOS-side inputs
/// (relay identity, TUN addresses, an optional punch/WSS loopback bridge, validated split-tunnel
/// rules) and hands them to the libbox binding's `OpenRungBuildSingBoxConfig`, whose emission
/// comes from the one Go builder every OpenRung client runs (`connectcore/client` in the sibling
/// `openrung` repo — the generator this file used to hand-copy). This file no longer emits any
/// config JSON; the DNS failover chains, probe pins, split-tunnel rules, route exclusions, and
/// their ordering all live in the shared builder, and the frozen bound outputs under
/// `testdata/singbox-binding/` are what this platform's structural tests assert against.
///
/// The assembly (`bindingInput(debug:)`) is engine-free so the pod-free test bundle can pin it;
/// the input→config half runs in `android/punchbridge`'s Go tests against the same checked-in
/// inputs. Unlike the Kotlin twin, the assembly never sends `excluded_packages` or
/// `route_find_process`: iOS has no OS-level per-app exclusion and never emits `find_process`.
public struct SingBoxConfiguration: Equatable, Sendable {
    /// The proxied DoH resolvers the shared builder emits by default (its defaults are the same
    /// IP literals). Kept here because the probe budgets below are derived from the chain's
    /// length and timeouts; the bound goldens pin the emitted list, so a builder-side change
    /// cannot drift past this constant unnoticed.
    public static let defaultDoHResolvers = ["1.1.1.1", "8.8.8.8"]

    // Per-evaluate budget before the next resolver runs, and the terminal/global budget — the
    // shared builder's dnsPrimaryTimeout/dnsFallbackTimeout, in milliseconds.
    public static let dnsPrimaryTimeoutMilliseconds: UInt64 = 2_000
    public static let dnsFallbackTimeoutMilliseconds: UInt64 = 3_000

    /// Engine-side worst case for one lookup through the default chain: every non-terminal
    /// resolver may consume its full evaluate timeout before the terminal fallback gets its
    /// own. Probe budgets are derived from this (see `PacketTunnelDnsProbe` and
    /// `PacketTunnelInternetProbe`) so they can never again abort an attempt while the chain
    /// is still legitimately working.
    public static let dnsFailoverWorstCaseMilliseconds: UInt64 =
        UInt64(defaultDoHResolvers.count - 1) * dnsPrimaryTimeoutMilliseconds
            + dnsFallbackTimeoutMilliseconds

    /// Default TUN IPv4 address; the DNS address below is derived from it.
    public static let defaultTunnelIPv4Address = "172.19.0.1/30"

    /// The ONLY in-TUN address whose port-53 traffic sing-box hijacks. When the tun inbound
    /// carries no explicit `dns_address` (the shared builder emits none), sing-tun derives the
    /// hijack address as the next address after the TUN's own IPv4 address, and the tun inbound
    /// tags a packet `Protocol=DNS` only when its destination equals that address — after which
    /// the router hijacks it into the DNS module ahead of any route rule. A datagram addressed to
    /// a public resolver (1.1.1.1) is NOT tagged, matches no rule, and dies on the TCP-only proxy
    /// outbound, so the fresh-DNS probe must target this address. It is also what libbox reports
    /// to `NEDNSSettings`, so it is exactly where system lookups already go.
    public static let defaultTunnelDnsAddress: String = {
        guard let address = tunnelDnsAddress(for: defaultTunnelIPv4Address) else {
            preconditionFailure(
                "default tunnel address has no derivable DNS address: \(defaultTunnelIPv4Address)"
            )
        }
        return address
    }()

    /// Next IPv4 address after `tunnelIPv4Address`, mirroring sing-tun's derivation, or nil for
    /// input that is not an IPv4 prefix.
    ///
    /// sing-tun only performs that derivation when the successor stays inside the TUN prefix
    /// (HasNextAddress: prefix.Contains(addr.Next())); otherwise it hijacks no IPv4 address at
    /// all. A tunnel address whose successor escapes the prefix therefore also yields nil —
    /// returning it would hand probes an address sing-box never hijacks and fail them on a
    /// healthy tunnel.
    public static func tunnelDnsAddress(for tunnelIPv4Address: String) -> String? {
        // omittingEmptySubsequences: false, or malformed input like "1..2.3.4/24" and
        // "1.2.3.4//24" collapses to a valid-looking shape.
        let parts = tunnelIPv4Address.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefixLength = Int(parts[1]), (0...32).contains(prefixLength) else {
            return nil
        }
        let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt64 = 0
        for octet in octets {
            guard let part = UInt64(octet), part <= 255 else { return nil }
            value = value << 8 | part
        }
        let next = value + 1
        let networkShift = UInt64(32 - prefixLength)
        guard value >> networkShift == next >> networkShift else { return nil }
        return [24, 16, 8, 0].map { String((next >> UInt64($0)) & 0xFF) }.joined(separator: ".")
    }

    public let relay: RelayDescriptor
    public let tunnelIPv4Address: String
    public let tunnelIPv6Address: String
    public let mtu: Int
    /// Optional loopback endpoint owned by a native access transport such as wsscore.
    public let bridgeHost: String?
    public let bridgePort: Int?
    /// Validated split-tunnel rules, or nil for full-tunnel behavior (byte-identical output to a
    /// build without split tunneling).
    public let splitTunnel: SplitTunnelRules?

    public init(
        relay: RelayDescriptor,
        tunnelIPv4Address: String = SingBoxConfiguration.defaultTunnelIPv4Address,
        tunnelIPv6Address: String = "fdfe:dcba:9876::1/126",
        mtu: Int = 1400,
        bridgeHost: String? = nil,
        bridgePort: Int? = nil,
        splitTunnel: SplitTunnelRules? = nil
    ) {
        self.relay = relay
        self.tunnelIPv4Address = tunnelIPv4Address
        self.tunnelIPv6Address = tunnelIPv6Address
        self.mtu = mtu
        self.bridgeHost = bridgeHost
        self.bridgePort = bridgePort
        self.splitTunnel = splitTunnel
    }

    /// The emitted config from the shared builder. Throws
    /// `SingBoxConfigurationError.rejected` when the binding rejects the input (an invalid
    /// relay, a partial bridge, an unsupported split-tunnel country, …) — the same failures the
    /// deleted generator used to reject locally.
    public func encodedJSON() throws -> Data {
        Data(try encodedJSONString().utf8)
    }

    public func encodedJSONString() throws -> String {
        #if canImport(Libbox)
        let result = LibboxOpenRungBuildSingBoxConfig(try serializedBindingInput())
        guard let result, result.succeeded() else {
            let reason = result?.errorText() ?? ""
            throw SingBoxConfigurationError.rejected(
                reason.isEmpty ? "sing-box config build failed" : reason
            )
        }
        return result.configJSON()
        #else
        // Only the engine-free test bundle compiles this branch (see project.yml); it pins the
        // assembly below and asserts against the frozen bound outputs instead of building live.
        throw SingBoxConfigurationError.engineUnavailable
        #endif
    }

    /// The binding input for this configuration: one JSON object of the platform-assembled
    /// fields. The relay object carries the broker's canonical wire names, the probe suffixes
    /// come from `ProbeTargets` so the builder's probe pins can never diverge from the endpoints
    /// this platform actually probes, and `debug` selects the log level ("info" logs every flow
    /// and DNS query — each line crosses the gomobile boundary and costs CPU inside the 50 MB
    /// extension, so release builds keep only warnings). Values are forwarded faithfully — a
    /// partial bridge is the binding's to reject, not this assembly's to repair.
    func bindingInput(debug: Bool) -> [String: Any] {
        var input: [String: Any] = [
            "relay": [
                "public_host": relay.publicHost,
                "public_port": relay.publicPort,
                "protocol": relay.relayProtocol,
                "client_id": relay.clientID,
                "reality_public_key": relay.realityPublicKey,
                "short_id": relay.shortID,
                "server_name": relay.serverName,
                "flow": relay.flow,
                "exit_mode": relay.exitMode,
            ] as [String: Any],
            "tunnel_ipv4_address": tunnelIPv4Address,
            "tunnel_ipv6_address": tunnelIPv6Address,
            "mtu": mtu,
            "log_level": debug ? "info" : "warn",
            "probe_domain_suffixes": ProbeTargets.ruleDomainSuffixes,
        ]
        if let bridgeHost { input["bridge_host"] = bridgeHost }
        if let bridgePort { input["bridge_port"] = bridgePort }
        if let splitTunnel {
            input["split_tunnel"] = [
                "bypass_lan": splitTunnel.bypassLan,
                "bypass_countries": splitTunnel.bypassCountries,
                "excluded_packages": [String](),
                "rule_set_directory": splitTunnel.ruleSetDirectory,
            ] as [String: Any]
        }
        return input
    }

    private func serializedBindingInput() throws -> String {
        #if DEBUG
        let debug = true
        #else
        let debug = false
        #endif
        let data = try JSONSerialization.data(withJSONObject: bindingInput(debug: debug))
        return String(decoding: data, as: UTF8.self)
    }
}

/// Failures of the bound sing-box builder, surfaced where the deleted generator used to throw.
public enum SingBoxConfigurationError: LocalizedError, Equatable {
    /// The binding rejected the assembled input; the message names the offending field.
    case rejected(String)
    /// Only the engine-free test bundle can see this: every shipping target links Libbox.
    case engineUnavailable

    public var errorDescription: String? {
        switch self {
        case .rejected(let reason):
            return "The sing-box configuration was rejected: \(reason)"
        case .engineUnavailable:
            return "The sing-box config builder is unavailable without the engine."
        }
    }
}
