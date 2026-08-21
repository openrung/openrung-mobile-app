import Foundation

/// Where the device is, for split-tunnel country defaults — the Swift port of
/// `src/model/splitTunnelDefaults.ts`, and the reason a background recovery can re-derive an
/// automatic country selection without any help from the RN process.
///
/// The IANA time zone is the only evidence used: offline, permission-free, and read fresh from the
/// OS on every call, so a device that changed zones while the app was suspended is seen correctly.
/// There is deliberately no locale fallback — a language preference is not evidence of physical
/// location, and guessing from it would put the China preset on exactly the diaspora devices this
/// protects.
public enum SplitTunnelRegion {
    public static let iran = "IR"
    public static let china = "CN"

    /// Zones that place the device inside a country with a bundled preset (canonical names plus
    /// the legacy aliases a device may still report). Hong Kong and Macau are deliberately absent:
    /// neither sits behind the GFW, so the mainland preset would cost them the tunnel without
    /// buying reachability.
    private static let regionByTimeZone: [String: String] = [
        "asia/tehran": iran,
        "iran": iran,
        "asia/shanghai": china,
        "asia/chongqing": china,
        "asia/chungking": china,
        "asia/harbin": china,
        "asia/urumqi": china,
        "asia/kashgar": china,
        "prc": china,
    ]

    /// ISO-3166 region for an IANA zone id, or "" when it carries no usable location.
    public static func region(forTimeZone timeZoneID: String) -> String {
        let normalized = timeZoneID.trimmingCharacters(in: .whitespaces).lowercased()
        if normalized == "utc" || normalized == "gmt" || normalized == "local"
            || normalized.hasPrefix("etc/") {
            return ""
        }
        return regionByTimeZone[normalized] ?? ""
    }

    /// ISO-3166 region for this device right now, or "" when the zone gives no usable answer.
    public static var deviceRegion: String {
        region(forTimeZone: TimeZone.current.identifier)
    }

    /// Bypass-country presets for a region; empty everywhere without a bundled rule set.
    public static func bypassCountries(forRegion region: String) -> [String] {
        switch region.uppercased() {
        case iran:
            return ["ir"]
        case china:
            return ["cn"]
        default:
            return []
        }
    }
}

/// The persisted split-tunnel preferences JSON pushed from React Native via
/// `setSplitTunnelConfig` (contract §3). Port of Android `SplitTunnelStore`'s config type:
/// snake_case keys, every field defaulted, unknown keys ignored (forward compat). iOS parses
/// `excluded_packages` but never acts on it — OS-level per-app exclusion is Android-only.
public struct SplitTunnelConfig: Codable, Equatable, Sendable {
    public static let countrySourceAuto = "auto"
    public static let countrySourceManual = "manual"

    public let version: Int
    public let enabled: Bool
    public let bypassLan: Bool
    public let bypassCountries: [String]
    /// `"auto"` when RN derived `bypassCountries` from the device region rather than the user
    /// choosing them, in which case `resolvedBypassCountries` re-derives here instead of trusting
    /// the stored snapshot. Defaults to manual so an older RN layer (which never sends the field)
    /// behaves exactly as before.
    public let countrySource: String
    public let excludedPackages: [String]

    enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case bypassLan = "bypass_lan"
        case bypassCountries = "bypass_countries"
        case countrySource = "country_source"
        case excludedPackages = "excluded_packages"
    }

    public init(
        version: Int = 1,
        enabled: Bool = false,
        bypassLan: Bool = true,
        bypassCountries: [String] = [],
        countrySource: String = SplitTunnelConfig.countrySourceManual,
        excludedPackages: [String] = []
    ) {
        self.version = version
        self.enabled = enabled
        self.bypassLan = bypassLan
        self.bypassCountries = bypassCountries
        self.countrySource = countrySource
        self.excludedPackages = excludedPackages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bypassLan = try container.decodeIfPresent(Bool.self, forKey: .bypassLan) ?? true
        bypassCountries = try container.decodeIfPresent([String].self, forKey: .bypassCountries) ?? []
        countrySource = try container.decodeIfPresent(String.self, forKey: .countrySource)
            ?? SplitTunnelConfig.countrySourceManual
        excludedPackages = try container.decodeIfPresent([String].self, forKey: .excludedPackages) ?? []
    }

    /// The countries this config actually asks for. An automatic selection is re-derived from
    /// `region` every time, because the stored list is only a snapshot of wherever the device was
    /// when JS last ran — and the extension rebuilds configs on its own after every physical-network
    /// change, while the app may not have been opened for weeks. A selection the user made by hand
    /// is always honored verbatim, however far the device has travelled.
    public func resolvedBypassCountries(
        region: String = SplitTunnelRegion.deviceRegion
    ) -> [String] {
        countrySource == Self.countrySourceAuto
            ? SplitTunnelRegion.bypassCountries(forRegion: region)
            : bypassCountries
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
        effectiveSignature(ofRawJSON: json, region: SplitTunnelRegion.deviceRegion)
    }

    /// As above, against an explicit region. Callers comparing two payloads should pass ONE region
    /// read to both, so a zone change landing between them cannot masquerade as a config change.
    public static func effectiveSignature(ofRawJSON json: String?, region: String) -> String {
        let disabled = "disabled"
        guard let json, let config = parse(json), config.enabled else { return disabled }
        var countries: [String] = []
        // The emission side re-derives an automatic selection, so the signature must too —
        // otherwise a push that flips country_source without changing bypass_countries would look
        // like a no-op while the emitted config actually changed.
        for code in config.resolvedBypassCountries(region: region).map({ $0.lowercased() }) {
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

/// The v1 bypass-country presets: the bundled sing-box rule-set tags per country. Each country's
/// direct-path resolver (or its documented absence) is the shared builder's now — see
/// `connectcore/client/singbox_split_tunnel.go` in the sibling `openrung` repo, whose emitted
/// shape the frozen goldens under `testdata/singbox-binding/` pin.
public struct SplitTunnelCountry: Equatable, Sendable {
    public let code: String
    public let geositeTag: String
    public let geoipTag: String

    /// Recognized countries in the normalized emission order: ir first, then cn. Unknown codes
    /// in a persisted config are ignored (forward compat).
    public static let supported: [SplitTunnelCountry] = [
        SplitTunnelCountry(
            code: "ir",
            geositeTag: "geosite-ir",
            geoipTag: "geoip-ir"
        ),
        SplitTunnelCountry(
            code: "cn",
            geositeTag: "geosite-cn",
            geoipTag: "geoip-cn"
        ),
    ]

    public static func forCode(_ code: String) -> SplitTunnelCountry? {
        supported.first { $0.code == code }
    }
}
