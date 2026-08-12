import Foundation

/// The persisted split-tunnel preferences JSON pushed from React Native via
/// `setSplitTunnelConfig` (contract §3). Port of Android `SplitTunnelStore`'s config type:
/// snake_case keys, every field defaulted, unknown keys ignored (forward compat). iOS parses
/// `excluded_packages` but never acts on it — OS-level per-app exclusion is Android-only.
public struct SplitTunnelConfig: Codable, Equatable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let bypassLan: Bool
    public let bypassCountries: [String]
    public let excludedPackages: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case bypassLan = "bypass_lan"
        case bypassCountries = "bypass_countries"
        case excludedPackages = "excluded_packages"
    }

    public init(
        version: Int = 1,
        enabled: Bool = false,
        bypassLan: Bool = true,
        bypassCountries: [String] = [],
        excludedPackages: [String] = []
    ) {
        self.version = version
        self.enabled = enabled
        self.bypassLan = bypassLan
        self.bypassCountries = bypassCountries
        self.excludedPackages = excludedPackages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bypassLan = try container.decodeIfPresent(Bool.self, forKey: .bypassLan) ?? true
        bypassCountries = try container.decodeIfPresent([String].self, forKey: .bypassCountries) ?? []
        excludedPackages = try container.decodeIfPresent([String].self, forKey: .excludedPackages) ?? []
    }

    /// Invalid or non-object JSON decodes to nil — fail-open (contract §1): a bad payload means
    /// "no split tunneling", never a failed connect.
    public static func parse(_ json: String) -> SplitTunnelConfig? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SplitTunnelConfig.self, from: data)
    }

    /// A canonical string that changes only when the emitted sing-box config would change on iOS.
    /// Two raw payloads that both resolve to disabled (or the same enabled rule set) share a
    /// signature, so a no-op push — e.g. the first persistence of a disabled config, or
    /// any change to `excluded_packages` (which iOS never emits) — is not treated as a change.
    public static func effectiveSignature(ofRawJSON json: String?) -> String {
        let disabled = "disabled"
        guard let json, let config = parse(json), config.enabled else { return disabled }
        var countries: [String] = []
        for code in config.bypassCountries.map({ $0.lowercased() }) {
            if SplitTunnelCountry.forCode(code) != nil, !countries.contains(code) {
                countries.append(code)
            }
        }
        countries.sort()
        // iOS deliberately ignores excluded_packages — a config that resolves to no LAN and no
        // surviving country produces the byte-identical baseline config.
        if !config.bypassLan, countries.isEmpty { return disabled }
        return "enabled|lan=\(config.bypassLan)|c=\(countries.joined(separator: ","))"
    }

    /// Reads the raw JSON the app persisted in the shared app-group defaults. Absence, a parse
    /// failure, and `enabled == false` all mean the same thing to callers: full-tunnel behavior.
    public static func load(from defaults: UserDefaults) -> SplitTunnelConfig? {
        guard
            let json = defaults.string(forKey: AppConfig.splitTunnelConfigDefaultsKey),
            let config = parse(json),
            config.enabled
        else {
            return nil
        }
        return config
    }
}

/// Decides whether an effective settings change may restart the current tunnel. Both the
/// extension-published lifecycle and NetworkExtension's system lifecycle must report a fully
/// connected tunnel. In particular, a path-loss recovery reports shared `connecting` and system
/// `reasserting`; restarting in that state would abort the recovery while it waits for a physical
/// network and could turn a self-healing session into a hard failure.
enum SplitTunnelReapplyPolicy {
    static func shouldReapply(
        effectiveConfigChanged: Bool,
        sharedTunnelIsConnected: Bool,
        systemTunnelIsConnected: Bool
    ) -> Bool {
        effectiveConfigChanged && sharedTunnelIsConnected && systemTunnelIsConnected
    }
}

/// Validated, ready-to-emit split-tunnel input for `SingBoxConfiguration` — NOT the persisted
/// JSON type above. The caller has already verified that both `.srs` files exist on disk for
/// every entry in `bypassCountries` and normalized their order to `SplitTunnelCountry.supported`
/// order. Unlike the Kotlin twin there is no `excludedPackages` field: iOS has no OS-level
/// per-app exclusion, so the Swift generator never emits `exclude_package`.
public struct SplitTunnelRules: Equatable, Sendable {
    public let bypassLan: Bool
    public let bypassCountries: [String]
    /// Absolute directory containing `geosite-<cc>.srs` / `geoip-<cc>.srs`.
    public let ruleSetDirectory: String

    public init(bypassLan: Bool, bypassCountries: [String], ruleSetDirectory: String) {
        self.bypassLan = bypassLan
        self.bypassCountries = bypassCountries
        self.ruleSetDirectory = ruleSetDirectory
    }
}

/// An in-country public resolver reached over the DIRECT path, so bypassed domains resolve to
/// in-country CDN nodes instead of the relay exit's view of them.
///
/// DoH over 443, never plaintext UDP/53: these queries leave the device on the user's real IP
/// while the tunnel is up, so the local network, the ISP and anything else on the path must not
/// get a cleartext list of the domains being bypassed (nor the chance to forge the answers).
/// `server` stays an IP literal so no bootstrap lookup is needed, and TLS authenticates
/// `tlsServerName` — the same shape the proxied DoH resolvers use.
public struct SplitTunnelDirectResolver: Equatable, Sendable {
    public let server: String
    public let tlsServerName: String

    public init(server: String, tlsServerName: String) {
        self.server = server
        self.tlsServerName = tlsServerName
    }
}

/// The v1 bypass-country presets, pairing the bundled sing-box rule-set tags with that country's
/// direct-path resolver.
public struct SplitTunnelCountry: Equatable, Sendable {
    public let code: String
    public let geositeTag: String
    public let geoipTag: String
    /// Nil when the country has no encrypted public resolver we can currently stand behind. Its
    /// bypass then keeps its ROUTE rules — the traffic still takes the direct path — and only its
    /// lookups fall to the proxied DoH chain, resolving through the relay exit's view. That costs
    /// in-country CDN affinity and nothing else.
    ///
    /// A resolver goes in here only while its certificate actually validates. Anything else is
    /// worse than omitting it: sing-box would spend the full evaluate timeout failing the TLS
    /// handshake on EVERY bypassed lookup before the fallback runs, so users would pay latency for
    /// an in-country answer they can never receive. Never restore one on the strength of its
    /// documentation — verify the live endpoint first.
    public let directResolver: SplitTunnelDirectResolver?

    /// Recognized countries in the normalized emission order: ir first, then cn. Unknown codes
    /// in a persisted config are ignored (forward compat).
    public static let supported: [SplitTunnelCountry] = [
        // Shecan is Iran's usual public resolver, but every endpoint it publishes
        // (178.22.122.100, 185.51.200.2, dns.shecan.ir) served an expired Let's Encrypt
        // certificate as of 2026-08-12 (notAfter Jul 10 2026), on both 443 and 853. Electro
        // (78.157.42.100) refuses both ports and Begzar's DoH host no longer resolves, so Iran
        // has no verifiable encrypted resolver to point at right now.
        SplitTunnelCountry(
            code: "ir",
            geositeTag: "geosite-ir",
            geoipTag: "geoip-ir",
            directResolver: nil
        ),
        // AliDNS (Chinese public resolver); https://223.5.5.5/dns-query is a published endpoint
        // and its certificate covers the IP literal.
        SplitTunnelCountry(
            code: "cn",
            geositeTag: "geosite-cn",
            geoipTag: "geoip-cn",
            directResolver: SplitTunnelDirectResolver(
                server: "223.5.5.5",
                tlsServerName: "dns.alidns.com"
            )
        ),
    ]

    public static func forCode(_ code: String) -> SplitTunnelCountry? {
        supported.first { $0.code == code }
    }
}
