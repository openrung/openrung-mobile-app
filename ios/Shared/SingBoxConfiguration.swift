import Foundation

/// iOS-side constants for the shared sing-box config builder, which runs inside connectcore
/// (`connectcore/client` in the sibling `openrung` repo). Go supplies the relay, bridge
/// endpoints, DNS chains, probe pins, split-tunnel rules and route exclusions; the platform
/// settings are assembled by `EngineTunnelSettings`, and this type keeps only the TUN/DNS
/// constants the probes derive their addresses and budgets from. The frozen bound outputs under
/// `testdata/singbox-binding/` are what this platform's structural tests assert against.
public enum SingBoxConfiguration {
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
}
