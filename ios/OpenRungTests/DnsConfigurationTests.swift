import Foundation
import XCTest

/// Regression tests for the DoH emission and the probe-priority pins. TCP/53 through the proxy
/// receives no replies under WSS relays, and geosite-cn contains probe-class hostnames
/// (www.gstatic.com), so both properties below are load-bearing for startup truthfulness.
/// Mirror of Android `SingBoxConfigurationDnsTest`.
final class DnsConfigurationTests: XCTestCase {
    private let ruleSetDirectory = "/var/rulesets"

    func testResolversAreEmittedAsDoHServersDetouredThroughTheProxy() throws {
        let servers = try proxiedDnsServers(SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject())
        XCTAssertEqual(servers.map { $0["tag"] as? String }, ["dns-0", "dns-1"])
        XCTAssertEqual(servers.map { $0["server"] as? String }, ["1.1.1.1", "8.8.8.8"])
        for server in servers {
            XCTAssertEqual(server["type"] as? String, "https")
            XCTAssertEqual(server["detour"] as? String, "proxy")
            // Defaults must stay in force: port 443 and path /dns-query.
            XCTAssertNil(server["server_port"])
            XCTAssertNil(server["path"])
            // IP-literal servers need no bootstrap resolver — the non-circularity guarantee.
            XCTAssertNil(server["domain_resolver"])
        }
    }

    func testNoProxiedDnsServerSpeaksPort53() throws {
        let object = SingBoxConfiguration(
            relay: makeWssTestRelay(),
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: ["ir", "cn"],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        for server in try XCTUnwrap(dns["servers"] as? [[String: Any]]) {
            if server["detour"] as? String == "proxy" {
                XCTAssertEqual(
                    server["type"] as? String,
                    "https",
                    "proxied resolvers must use DoH over 443"
                )
            }
        }
    }

    func testFinalAndDefaultDomainResolverStayPinnedToThePrimary() throws {
        let object = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        XCTAssertEqual(dns["final"] as? String, "dns-0")
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-0")
    }

    func testProbeDnsPinIsAlwaysFirstProxiedAndUncached() throws {
        let baseline = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()
        let china = SingBoxConfiguration(
            relay: makeWssTestRelay(),
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: ["cn"],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()

        for object in [baseline, china] {
            let dns = try XCTUnwrap(object["dns"] as? [String: Any])
            let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
            let probeRule = try XCTUnwrap(rules.first)
            XCTAssertEqual(probeRule["domain_suffix"] as? [String], ProbeTargets.ruleDomainSuffixes)
            XCTAssertEqual(probeRule["server"] as? String, "dns-0")
            XCTAssertEqual(probeRule["disable_cache"] as? Bool, true)

            // Resolve the pinned tag: the rule is only meaningful if the server it names is
            // itself DoH-through-proxy. This is the premise StartupPathVerificationTests relies
            // on for the cn shape (every probe flow proxied).
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            let target = try XCTUnwrap(servers.first {
                $0["tag"] as? String == probeRule["server"] as? String
            })
            XCTAssertEqual(target["type"] as? String, "https")
            XCTAssertEqual(target["detour"] as? String, "proxy")
        }
    }

    func testProbeQueriesTargetTheOnlyAddressSingBoxHijacks() throws {
        // sing-box tags a packet as DNS — and hijacks it into the DNS module ahead of every
        // route rule — ONLY when its destination equals the TUN's derived DNS address (the next
        // address after the TUN's own IPv4 address, since we emit no dns_address). A probe sent
        // to a public resolver instead would match no rule and die on the TCP-only proxy
        // outbound, failing on every healthy tunnel.
        XCTAssertEqual(SingBoxConfiguration.defaultTunnelIPv4Address, "172.19.0.1/30")
        XCTAssertEqual(SingBoxConfiguration.defaultTunnelDnsAddress, "172.19.0.2")
        XCTAssertEqual(
            SingBoxConfiguration.tunnelDnsAddress(
                for: SingBoxConfiguration(relay: makeWssTestRelay()).tunnelIPv4Address
            ),
            SingBoxConfiguration.defaultTunnelDnsAddress
        )
        // Octet carry, so a future tunnel address change cannot silently derive a wrong address.
        XCTAssertEqual(SingBoxConfiguration.tunnelDnsAddress(for: "10.0.0.255/30"), "10.0.1.0")

        // An explicit dns_address on the tun inbound would replace the derived hijack address
        // and silently invalidate the probe target above.
        let object = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        XCTAssertNil(try XCTUnwrap(inbounds.first)["dns_address"])
    }

    func testDnsBlockIsIdenticalAcrossDirectAndBridgedShapes() throws {
        let relay = makeWssTestRelay()
        let direct = SingBoxConfiguration(relay: relay).makeJSONObject()
        let bridged = SingBoxConfiguration(
            relay: relay,
            bridgeHost: "127.0.0.1",
            bridgePort: 54_321
        ).makeJSONObject()
        XCTAssertEqual(
            try JSONSerialization.data(withJSONObject: XCTUnwrap(direct["dns"]), options: [.sortedKeys]),
            try JSONSerialization.data(withJSONObject: XCTUnwrap(bridged["dns"]), options: [.sortedKeys])
        )
    }

    func testChinaBypassCanNeverOutrankTheProbePins() throws {
        // The confirmed regression: geosite-cn contains www.gstatic.com, so before these pins a
        // dead proxy still produced a passing probe over the direct path and the app published
        // CONNECTED. Probe DNS and probe routing must both win before any country rule.
        let object = SingBoxConfiguration(
            relay: makeWssTestRelay(),
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: ["cn"],
                ruleSetDirectory: ruleSetDirectory
            )
        ).makeJSONObject()

        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        let dnsRules = try XCTUnwrap(dns["rules"] as? [[String: Any]])
        XCTAssertNotNil(dnsRules[0]["domain_suffix"])
        XCTAssertEqual(dnsRules[0]["server"] as? String, "dns-0")
        let countryDnsIndex = dnsRules.firstIndex { $0["rule_set"] != nil }
        XCTAssertEqual(countryDnsIndex, 1)

        let route = try XCTUnwrap(object["route"] as? [String: Any])
        let routeRules = try XCTUnwrap(route["rules"] as? [[String: Any]])
        let probeIndex = try XCTUnwrap(routeRules.firstIndex {
            $0["domain_suffix"] as? [String] == ProbeTargets.ruleDomainSuffixes
        })
        let bypassIndex = try XCTUnwrap(routeRules.firstIndex {
            $0["outbound"] as? String == "direct"
        })
        XCTAssertEqual(routeRules[probeIndex]["outbound"] as? String, "proxy")
        XCTAssertLessThan(probeIndex, bypassIndex, "probe route pin must precede every bypass rule")
    }

    func testRotatedResolverOrderSwapsTheFinalResolver() throws {
        let rotation = DnsResolverRotation()
        XCTAssertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))

        let servers = try proxiedDnsServers(
            SingBoxConfiguration(
                relay: makeWssTestRelay(),
                dnsServers: rotation.currentServers()
            ).makeJSONObject()
        )
        XCTAssertEqual(servers[0]["tag"] as? String, "dns-0")
        XCTAssertEqual(servers[0]["server"] as? String, "8.8.8.8")
        XCTAssertEqual(servers[1]["server"] as? String, "1.1.1.1")
    }

    func testEveryThroughTunnelProbeEndpointIsCoveredByTheRulePins() throws {
        for endpoint in PacketTunnelInternetProbe.defaultEndpointStrings + InternetProbe.defaultEndpoints {
            let host = try XCTUnwrap(URL(string: endpoint)?.host)
            XCTAssertTrue(
                ProbeTargets.ruleDomainSuffixes.contains { suffix in
                    host == suffix || host.hasSuffix(".\(suffix)")
                },
                "probe endpoint \(host) must be pinned through the proxy"
            )
        }
        // The fresh-DNS nonce queries must land under a pinned suffix too.
        XCTAssertTrue(ProbeTargets.ruleDomainSuffixes.contains(ProbeTargets.dnsProbeQnameSuffix))
    }

    private func proxiedDnsServers(_ object: [String: Any]) throws -> [[String: Any]] {
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        return try XCTUnwrap(dns["servers"] as? [[String: Any]]).filter { server in
            let tag = server["tag"] as? String ?? ""
            return tag.hasPrefix("dns-") && !tag.hasPrefix("dns-direct-")
        }
    }
}
