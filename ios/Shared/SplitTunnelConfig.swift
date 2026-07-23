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
    /// signature, so a no-op push — e.g. the first persistence of the default disabled config, or
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

/// The v1 bypass-country presets. Each pairs the bundled sing-box rule-set tags with an
/// in-country public DNS resolver used over the direct path, so bypassed domains resolve to
/// in-country CDN nodes instead of the relay exit's view of them.
public struct SplitTunnelCountry: Equatable, Sendable {
    public let code: String
    public let geositeTag: String
    public let geoipTag: String
    public let directResolver: String

    /// Recognized countries in the normalized emission order: ir first, then cn. Unknown codes
    /// in a persisted config are ignored (forward compat).
    public static let supported: [SplitTunnelCountry] = [
        // Shecan (Iranian public resolver).
        SplitTunnelCountry(
            code: "ir",
            geositeTag: "geosite-ir",
            geoipTag: "geoip-ir",
            directResolver: "178.22.122.100"
        ),
        // AliDNS (Chinese public resolver).
        SplitTunnelCountry(
            code: "cn",
            geositeTag: "geosite-cn",
            geoipTag: "geoip-cn",
            directResolver: "223.5.5.5"
        ),
    ]

    public static func forCode(_ code: String) -> SplitTunnelCountry? {
        supported.first { $0.code == code }
    }
}
