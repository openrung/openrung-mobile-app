import Foundation

/// The through-tunnel connectivity-probe targets shared by the startup/health probes and the
/// sing-box emission (`SingBoxConfiguration`). These hostnames are pinned through the proxy by
/// the highest-priority DNS and route rules, so a country-bypass rule set that happens to
/// contain a probe hostname (geosite-cn ships www.gstatic.com) can never route the probe onto
/// the direct path and prove nothing about the tunnel. Mirrors Android `ProbeTargets`.
public enum ProbeTargets {
    /// Dedicated probe hostname on OpenRung infrastructure; used for nothing but probing.
    public static let dedicatedHost = "probe.openrung.org"

    /// Third-party fallback so a dedicated-infra outage cannot fail every startup.
    public static let fallbackHost = "cp.cloudflare.com"

    /// Through-tunnel HTTPS probe endpoints, dedicated hostname first.
    public static let tunnelProbeURLs = [
        "https://\(dedicatedHost)/generate_204",
        "https://\(fallbackHost)/generate_204",
    ]

    /// Every hostname the priority DNS/route rules must capture (suffix match).
    public static let ruleDomainSuffixes = [dedicatedHost, fallbackHost]

    /// Fresh-DNS probes query `<nonce>.` + this suffix; any response proves the path.
    public static let dnsProbeQnameSuffix = dedicatedHost
}
