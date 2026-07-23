import Foundation
import XCTest

final class SplitTunnelConfigurationTests: XCTestCase {
    private static let testDefaultsSuite = "com.openrung.tests.split-tunnel"
    private let ruleSetDirectory = "/var/rulesets"

    // MARK: - sing-box emission (spec §2; byte-parallel with the Kotlin generator)

    func testNilAndInertRulesEmitBaselineConfig() throws {
        let relay = makeWssTestRelay()
        let baseline = SingBoxConfiguration(relay: relay).makeJSONObject()
        let explicitNil = SingBoxConfiguration(relay: relay, splitTunnel: nil).makeJSONObject()
        // Callers pass nil when disabled, but rules contributing nothing must also be a no-op.
        let inert = SingBoxConfiguration(
            relay: relay,
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: [],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()

        XCTAssertEqual(try canonicalJSON(baseline), try canonicalJSON(explicitNil))
        XCTAssertEqual(try canonicalJSON(baseline), try canonicalJSON(inert))
    }

    func testLanOnlyRulesAddExactlyOnePrivateBypassRouteRule() throws {
        let relay = makeWssTestRelay()
        var baseline = SingBoxConfiguration(relay: relay).makeJSONObject()
        var split = SingBoxConfiguration(
            relay: relay,
            splitTunnel: SplitTunnelRules(
                bypassLan: true,
                bypassCountries: [],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()

        let route = try XCTUnwrap(split["route"] as? [String: Any])
        XCTAssertNil(route["rule_set"])
        XCTAssertEqual(try canonicalJSON(route["rules"]), try canonicalJSON([
            ["protocol": "dns", "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"],
        ] as [[String: Any]]))

        // Everything outside route — dns (no "rules" key), tun inbound, outbounds — is untouched.
        baseline.removeValue(forKey: "route")
        split.removeValue(forKey: "route")
        XCTAssertEqual(try canonicalJSON(baseline), try canonicalJSON(split))
    }

    func testIranOnlyRulesEmitDnsAndRouteDeltasInOrder() throws {
        let object = SingBoxConfiguration(
            relay: makeWssTestRelay(),
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: ["ir"],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()

        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.count, 3)
        XCTAssertEqual(try canonicalJSON(servers[2]), try canonicalJSON([
            "tag": "dns-direct-ir",
            "type": "udp",
            "server": "178.22.122.100",
            "detour": "direct",
        ] as [String: Any]))
        XCTAssertEqual(try canonicalJSON(dns["rules"]), try canonicalJSON([
            ["rule_set": ["geosite-ir"], "server": "dns-direct-ir"],
        ] as [[String: Any]]))

        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(try canonicalJSON(route["rules"]), try canonicalJSON([
            ["protocol": "dns", "action": "hijack-dns"],
            ["action": "sniff"],
            ["rule_set": ["geosite-ir", "geoip-ir"], "outbound": "direct"],
        ] as [[String: Any]]))
        XCTAssertEqual(try canonicalJSON(route["rule_set"]), try canonicalJSON([
            ["type": "local", "tag": "geosite-ir", "format": "binary", "path": "/var/rulesets/geosite-ir.srs"],
            ["type": "local", "tag": "geoip-ir", "format": "binary", "path": "/var/rulesets/geoip-ir.srs"],
        ] as [[String: Any]]))
    }

    func testFullRulesEmitIranBeforeChinaAndLeaveTheRestUntouched() throws {
        let relay = makeWssTestRelay()
        var baseline = SingBoxConfiguration(relay: relay).makeJSONObject()
        var split = SingBoxConfiguration(relay: relay, splitTunnel: fullRules).makeJSONObject()

        let dns = try XCTUnwrap(split["dns"] as? [String: Any])
        let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
        XCTAssertEqual(servers.map { $0["tag"] as? String }, ["dns-0", "dns-1", "dns-direct-ir", "dns-direct-cn"])
        XCTAssertEqual(servers[3]["server"] as? String, "223.5.5.5")
        XCTAssertEqual(try canonicalJSON(dns["rules"]), try canonicalJSON([
            ["rule_set": ["geosite-ir"], "server": "dns-direct-ir"],
            ["rule_set": ["geosite-cn"], "server": "dns-direct-cn"],
        ] as [[String: Any]]))

        let route = try XCTUnwrap(split["route"] as? [String: Any])
        XCTAssertEqual(try canonicalJSON(route["rules"]), try canonicalJSON([
            ["protocol": "dns", "action": "hijack-dns"],
            ["action": "sniff"],
            ["ip_is_private": true, "outbound": "direct"],
            ["rule_set": ["geosite-ir", "geoip-ir"], "outbound": "direct"],
            ["rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct"],
        ] as [[String: Any]]))
        let ruleSets = try XCTUnwrap(route["rule_set"] as? [[String: Any]])
        XCTAssertEqual(
            ruleSets.map { $0["tag"] as? String },
            ["geosite-ir", "geoip-ir", "geosite-cn", "geoip-cn"]
        )

        // The iOS generator NEVER emits per-app exclusions (Android-only), and everything
        // outside dns/route stays byte-identical.
        let tun = try firstInbound(split)
        XCTAssertNil(tun["exclude_package"])
        XCTAssertNil(tun["include_package"])
        for key in ["dns", "route"] {
            baseline.removeValue(forKey: key)
            split.removeValue(forKey: key)
        }
        XCTAssertEqual(try canonicalJSON(baseline), try canonicalJSON(split))
    }

    func testBridgeModeKeepsSplitRulesAndStillOmitsRouteExcludeAddress() throws {
        let relay = makeWssTestRelay()
        let direct = SingBoxConfiguration(relay: relay, splitTunnel: fullRules).makeJSONObject()
        let bridged = SingBoxConfiguration(
            relay: relay,
            bridgeHost: "127.0.0.1",
            bridgePort: 24_680,
            splitTunnel: fullRules
        ).makeJSONObject()

        XCTAssertEqual(try canonicalJSON(direct["dns"]), try canonicalJSON(bridged["dns"]))
        XCTAssertEqual(try canonicalJSON(direct["route"]), try canonicalJSON(bridged["route"]))
        // Leak-precedent regression guard: the bridge's loopback endpoint stays inside the TUN.
        let bridgedTun = try firstInbound(bridged)
        XCTAssertNil(bridgedTun["route_exclude_address"])
    }

    func testCountryConstantsMatchSpec() {
        XCTAssertEqual(SplitTunnelCountry.supported.map(\.code), ["ir", "cn"])
        XCTAssertEqual(SplitTunnelCountry.forCode("ir")?.geositeTag, "geosite-ir")
        XCTAssertEqual(SplitTunnelCountry.forCode("ir")?.geoipTag, "geoip-ir")
        XCTAssertEqual(SplitTunnelCountry.forCode("ir")?.directResolver, "178.22.122.100")
        XCTAssertEqual(SplitTunnelCountry.forCode("cn")?.geositeTag, "geosite-cn")
        XCTAssertEqual(SplitTunnelCountry.forCode("cn")?.geoipTag, "geoip-cn")
        XCTAssertEqual(SplitTunnelCountry.forCode("cn")?.directResolver, "223.5.5.5")
        XCTAssertNil(SplitTunnelCountry.forCode("us"))
    }

    // MARK: - Persisted config parsing (spec §1)

    func testConfigParsingAppliesDefaultsAndToleratesUnknownKeys() throws {
        let full = SplitTunnelConfig.parse(
            #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir","cn"],"excluded_packages":["com.tencent.mm"]}"#
        )
        XCTAssertEqual(full, SplitTunnelConfig(
            version: 1,
            enabled: true,
            bypassLan: true,
            bypassCountries: ["ir", "cn"],
            excludedPackages: ["com.tencent.mm"]
        ))

        let sparse = try XCTUnwrap(
            SplitTunnelConfig.parse(#"{"enabled":true,"future_field":{"nested":true}}"#)
        )
        XCTAssertEqual(sparse.version, 1)
        XCTAssertTrue(sparse.bypassLan)
        XCTAssertEqual(sparse.bypassCountries, [])
        XCTAssertEqual(sparse.excludedPackages, [])
    }

    func testInvalidJSONParsesToNil() {
        XCTAssertNil(SplitTunnelConfig.parse("not json"))
        XCTAssertNil(SplitTunnelConfig.parse("[]"))
        XCTAssertNil(SplitTunnelConfig.parse(#"{"enabled":"yes"}"#))
    }

    func testLoadReturnsNilForAbsenceParseFailureAndDisabledConfig() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.testDefaultsSuite))
        defaults.removePersistentDomain(forName: Self.testDefaultsSuite)
        defer { defaults.removePersistentDomain(forName: Self.testDefaultsSuite) }

        XCTAssertNil(SplitTunnelConfig.load(from: defaults), "absent key must read as no split tunneling")

        defaults.set("not json", forKey: AppConfig.splitTunnelConfigDefaultsKey)
        XCTAssertNil(SplitTunnelConfig.load(from: defaults), "a broken payload must fail open")

        let disabled = #"{"version":1,"enabled":false,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}"#
        defaults.set(disabled, forKey: AppConfig.splitTunnelConfigDefaultsKey)
        XCTAssertNotNil(SplitTunnelConfig.parse(disabled), "enabled:false still parses")
        XCTAssertNil(SplitTunnelConfig.load(from: defaults), "enabled:false must read as no split tunneling")

        let enabled = #"{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["ir"],"excluded_packages":[]}"#
        defaults.set(enabled, forKey: AppConfig.splitTunnelConfigDefaultsKey)
        let loaded = try XCTUnwrap(SplitTunnelConfig.load(from: defaults))
        XCTAssertFalse(loaded.bypassLan)
        XCTAssertEqual(loaded.bypassCountries, ["ir"])
    }

    func testEffectiveSignatureTreatsNoOpAndPackageOnlyChangesAsUnchanged() {
        let sig = SplitTunnelConfig.effectiveSignature(ofRawJSON:)

        // Absence, unparseable, and every disabled/inert form share the "disabled" signature, so a
        // first push of the default config never bounces a live tunnel.
        XCTAssertEqual(sig(nil), sig(#"{"version":1,"enabled":false,"bypass_lan":true}"#))
        XCTAssertEqual(sig("not json"), sig(nil))
        XCTAssertEqual(
            sig(#"{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":[]}"#),
            sig(nil),
            "enabled but with no LAN/country rule is effectively disabled"
        )

        // iOS never emits exclude_package, so a packages-only difference is NOT an effective change.
        let noPackages = #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}"#
        let withPackages = #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":["com.tencent.mm"]}"#
        XCTAssertEqual(sig(noPackages), sig(withPackages))

        // A real routing change (LAN, or a recognized country) does change the signature.
        XCTAssertNotEqual(sig(nil), sig(noPackages))
        XCTAssertNotEqual(
            sig(#"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":[]}"#),
            sig(nil)
        )
        // Unrecognized countries resolve away, so they don't count as an effective change.
        XCTAssertEqual(
            sig(#"{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["xx"]}"#),
            sig(nil)
        )
    }

    // MARK: - Helpers

    private var fullRules: SplitTunnelRules {
        SplitTunnelRules(
            bypassLan: true,
            bypassCountries: ["ir", "cn"],
            ruleSetDirectory: ruleSetDirectory
        )
    }

    private func firstInbound(_ object: [String: Any]) throws -> [String: Any] {
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        return try XCTUnwrap(inbounds.first)
    }

    private func canonicalJSON(_ object: Any?) throws -> Data {
        try JSONSerialization.data(withJSONObject: XCTUnwrap(object), options: [.sortedKeys])
    }
}
