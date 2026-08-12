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

        // Everything outside route — dns (incl. the always-on probe rule), tun inbound,
        // outbounds — is untouched.
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

        // Iran has no encrypted public resolver we can currently stand behind, so it contributes
        // no dns server and no dns rules at all — its ROUTE bypass below is untouched, and its
        // lookups just reach the proxied global chain. A dead primary would be strictly worse:
        // every bypassed lookup would burn the full evaluate timeout on a doomed TLS handshake.
        let baselineDns = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()["dns"]
        XCTAssertEqual(try canonicalJSON(object["dns"]), try canonicalJSON(baselineDns))

        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(try canonicalJSON(route["rules"]), try canonicalJSON([
            ["protocol": "dns", "action": "hijack-dns"],
            ["action": "sniff"],
            ["domain_suffix": ProbeTargets.ruleDomainSuffixes, "outbound": "proxy"],
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
        // Only China contributes a resolver today (see SplitTunnelCountry.directResolver), but the
        // ROUTE rules below still cover both countries.
        XCTAssertEqual(servers.map { $0["tag"] as? String }, ["dns-0", "dns-1", "dns-direct-cn"])
        XCTAssertEqual(servers[2]["server"] as? String, "223.5.5.5")
        XCTAssertEqual(
            (servers[2]["tls"] as? [String: Any])?["server_name"] as? String,
            "dns.alidns.com"
        )
        // Every resolver encrypted, and the bypass resolver still detour-less (a detour to the
        // empty direct outbound is rejected at engine start).
        XCTAssertTrue(servers.allSatisfy { $0["type"] as? String == "https" })
        XCTAssertNil(servers[2]["detour"])
        XCTAssertEqual(try canonicalJSON(dns["rules"]), try canonicalJSON(
            expectedProbeFailoverChain()
                + expectedCountryFailoverChain(geositeTag: "geosite-cn", server: "dns-direct-cn")
                + expectedGlobalFailoverChain()
        ))

        let route = try XCTUnwrap(split["route"] as? [String: Any])
        XCTAssertEqual(try canonicalJSON(route["rules"]), try canonicalJSON([
            ["protocol": "dns", "action": "hijack-dns"],
            ["action": "sniff"],
            ["domain_suffix": ProbeTargets.ruleDomainSuffixes, "outbound": "proxy"],
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
        // Iran ships no resolver while Shecan's certificate is expired; see the type's docs
        // before restoring one, and verify the live endpoint rather than its documentation.
        XCTAssertNil(SplitTunnelCountry.forCode("ir")?.directResolver)
        XCTAssertEqual(SplitTunnelCountry.forCode("cn")?.geositeTag, "geosite-cn")
        XCTAssertEqual(SplitTunnelCountry.forCode("cn")?.geoipTag, "geoip-cn")
        XCTAssertEqual(
            SplitTunnelCountry.forCode("cn")?.directResolver,
            SplitTunnelDirectResolver(server: "223.5.5.5", tlsServerName: "dns.alidns.com")
        )
        XCTAssertNil(SplitTunnelCountry.forCode("us"))
    }

    // MARK: - Region detection and automatic-country resolution

    /// Must stay behaviourally identical to `src/model/splitTunnelDefaults.ts` and the Kotlin port.
    /// The whole point is that the extension can answer "where is this device now?" itself, without
    /// the RN process, so a background recovery after a physical-network change rebuilds with the
    /// right rule set.
    func testRegionDetectionFromTimeZone() {
        XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: "Asia/Tehran"), "IR")
        XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: "Iran"), "IR")
        XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: "Asia/Shanghai"), "CN")
        XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: "Asia/Urumqi"), "CN")
        XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: "PRC"), "CN")

        // Hong Kong and Macau are deliberately not mainland: neither sits behind the GFW.
        for zone in [
            "Europe/Berlin", "America/Los_Angeles", "Asia/Hong_Kong", "Asia/Macau",
            "UTC", "GMT", "Etc/UTC", "Etc/GMT+3", "local", "",
        ] {
            XCTAssertEqual(SplitTunnelRegion.region(forTimeZone: zone), "", "no region for \(zone)")
        }

        XCTAssertEqual(SplitTunnelRegion.bypassCountries(forRegion: "IR"), ["ir"])
        XCTAssertEqual(SplitTunnelRegion.bypassCountries(forRegion: "CN"), ["cn"])
        XCTAssertEqual(SplitTunnelRegion.bypassCountries(forRegion: ""), [])
        XCTAssertEqual(SplitTunnelRegion.bypassCountries(forRegion: "DE"), [])
    }

    func testAutomaticSelectionIsRederivedWhileHandPickedIsHonored() throws {
        // The travel case RN alone cannot fix: the app auto-selected cn in Shanghai and has not
        // been opened since, but the extension is rebuilding its config in Berlin.
        let auto = try XCTUnwrap(SplitTunnelConfig.parse(
            #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],"country_source":"auto","excluded_packages":[]}"#
        ))
        XCTAssertEqual(auto.resolvedBypassCountries(region: "CN"), ["cn"])
        XCTAssertEqual(auto.resolvedBypassCountries(region: ""), [])
        XCTAssertEqual(auto.resolvedBypassCountries(region: "IR"), ["ir"])

        let manual = try XCTUnwrap(SplitTunnelConfig.parse(
            #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["cn"],"country_source":"manual","excluded_packages":[]}"#
        ))
        for region in ["CN", "", "IR"] {
            XCTAssertEqual(manual.resolvedBypassCountries(region: region), ["cn"])
        }

        // A config from an older RN layer carries no source and is treated as hand-picked.
        let legacy = try XCTUnwrap(SplitTunnelConfig.parse(
            #"{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":["ir"],"excluded_packages":[]}"#
        ))
        XCTAssertEqual(legacy.countrySource, SplitTunnelConfig.countrySourceManual)
        XCTAssertEqual(legacy.resolvedBypassCountries(region: ""), ["ir"])
    }

    func testEffectiveSignatureFollowsTheRederivedCountries() {
        let autoCn =
            #"{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["cn"],"country_source":"auto","excluded_packages":[]}"#
        let manualCn =
            #"{"version":1,"enabled":true,"bypass_lan":false,"bypass_countries":["cn"],"country_source":"manual","excluded_packages":[]}"#

        // In China both resolve to cn, so declaring the same list hand-picked changes nothing.
        XCTAssertEqual(
            SplitTunnelConfig.effectiveSignature(ofRawJSON: autoCn, region: "CN"),
            SplitTunnelConfig.effectiveSignature(ofRawJSON: manualCn, region: "CN")
        )
        // Outside China the automatic one resolves to no country, so the emitted config differs —
        // the signature must track that, not the stored snapshot.
        XCTAssertNotEqual(
            SplitTunnelConfig.effectiveSignature(ofRawJSON: autoCn, region: ""),
            SplitTunnelConfig.effectiveSignature(ofRawJSON: manualCn, region: "")
        )
        // An automatic selection with nothing else effective is indistinguishable from disabled.
        XCTAssertEqual(
            SplitTunnelConfig.effectiveSignature(ofRawJSON: autoCn, region: ""),
            SplitTunnelConfig.effectiveSignature(ofRawJSON: nil)
        )
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

    func testReapplyRequiresEffectiveChangeAndBothLifecyclesToBeFullyConnected() {
        XCTAssertTrue(
            SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: true,
                sharedTunnelIsConnected: true,
                systemTunnelIsConnected: true
            )
        )
        XCTAssertFalse(
            SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: false,
                sharedTunnelIsConnected: true,
                systemTunnelIsConnected: true
            ),
            "an ineffective config push must not bounce a live tunnel"
        )
        XCTAssertFalse(
            SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: true,
                sharedTunnelIsConnected: false,
                systemTunnelIsConnected: true
            ),
            "shared connecting during path-loss recovery must not be interrupted"
        )
        XCTAssertFalse(
            SplitTunnelReapplyPolicy.shouldReapply(
                effectiveConfigChanged: true,
                sharedTunnelIsConnected: true,
                systemTunnelIsConnected: false
            ),
            "system connecting or reasserting must not be treated as fully connected"
        )
    }

    // MARK: - Helpers

    /// The always-emitted probe DNS chain (spec §2): evaluate the primary uncached, respond on
    /// any real answer (NOERROR/NXDOMAIN — nonce probes draw the latter), else the terminal
    /// fallback route. Scoped to the probe domains and terminal for them.
    private func expectedProbeFailoverChain() -> [[String: Any]] {
        [
            [
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "action": "evaluate",
                "server": "dns-0",
                "timeout": "2s",
                "disable_cache": true,
                "disable_optimistic_cache": true,
            ],
            [
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "match_response": true,
                "response_rcode": "NOERROR",
                "action": "respond",
            ],
            [
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "match_response": true,
                "response_rcode": "NXDOMAIN",
                "action": "respond",
            ],
            [
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "server": "dns-1",
                "timeout": "3s",
                "disable_cache": true,
                "disable_optimistic_cache": true,
            ],
        ]
    }

    /// A bypass country's DNS chain: ask its in-country DoH resolver, keep only a real answer,
    /// and otherwise fall through to the proxied global chain rather than failing the lookup —
    /// so an unreachable or expired-certificate resolver costs latency, not reachability.
    private func expectedCountryFailoverChain(geositeTag: String, server: String) -> [[String: Any]] {
        [
            [
                "rule_set": [geositeTag],
                "action": "evaluate",
                "server": server,
                "timeout": "2s",
            ],
            [
                "rule_set": [geositeTag],
                "match_response": true,
                "response_rcode": "NOERROR",
                "action": "respond",
            ],
            [
                "rule_set": [geositeTag],
                "match_response": true,
                "response_rcode": "NXDOMAIN",
                "action": "respond",
            ],
        ]
    }

    /// The always-emitted global failover chain: same shape, unscoped and cache-friendly.
    private func expectedGlobalFailoverChain() -> [[String: Any]] {
        [
            ["action": "evaluate", "server": "dns-0", "timeout": "2s"],
            ["match_response": true, "response_rcode": "NOERROR", "action": "respond"],
            ["match_response": true, "response_rcode": "NXDOMAIN", "action": "respond"],
            ["server": "dns-1", "timeout": "3s"],
        ]
    }

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
