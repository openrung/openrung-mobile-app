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
        // TLS authenticates the provider hostname while the dial stays on the IP literal, so a
        // provider dropping IP SANs from its certificate cannot break resolution.
        XCTAssertEqual(
            servers.map { ($0["tls"] as? [String: Any])?["server_name"] as? String },
            ["cloudflare-dns.com", "dns.google"]
        )
    }

    func testNoDnsServerAnywhereSpeaksPlaintextDns() throws {
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
            // Proxied resolvers need DoH because relays answer 443 on every transport while
            // TCP/53 gets no replies under WSS. The bypass-country resolvers need it for a
            // different reason: they are dialed DIRECTLY, so an unencrypted query would leave
            // the device on the user's real IP — in cleartext, and forgeable — while the tunnel
            // is up. Neither may ever regress to udp/tcp.
            let tag = server["tag"] as? String ?? "?"
            XCTAssertEqual(server["type"] as? String, "https", "\(tag) must be encrypted")
            XCTAssertNotNil(
                (server["tls"] as? [String: Any])?["server_name"],
                "\(tag) must authenticate a provider hostname"
            )
        }
    }

    func testDefaultDomainResolverStaysOnPrimaryAndFinalOnTerminalFallback() throws {
        let object = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        // The global chain's trailing route rule is the real terminus; `final` names the same
        // fallback resolver for coherence.
        XCTAssertEqual(dns["final"] as? String, "dns-1")
        XCTAssertEqual(dns["timeout"] as? String, "3s")
        let route = try XCTUnwrap(object["route"] as? [String: Any])
        XCTAssertEqual(route["default_domain_resolver"] as? String, "dns-0")
    }

    func testFailoverChainEvaluatesThePrimaryThenFallsToTheTerminalFallback() throws {
        // sing-box has no upstream failover of its own: `evaluate` is non-terminal on a
        // transport error/timeout/SERVFAIL/REFUSED, `respond` returns a usable answer (NOERROR,
        // or an authoritative NXDOMAIN), and the trailing route rule is the terminal fallback.
        let object = SingBoxConfiguration(relay: makeWssTestRelay()).makeJSONObject()
        let dns = try XCTUnwrap(object["dns"] as? [String: Any])
        let rules = try XCTUnwrap(dns["rules"] as? [[String: Any]]).suffix(4).map { $0 }
        XCTAssertEqual(rules[0]["action"] as? String, "evaluate")
        XCTAssertEqual(rules[0]["server"] as? String, "dns-0")
        XCTAssertEqual(rules[0]["timeout"] as? String, "2s")
        for (rcode, rule) in [("NOERROR", rules[1]), ("NXDOMAIN", rules[2])] {
            XCTAssertEqual(rule["match_response"] as? Bool, true)
            XCTAssertEqual(rule["response_rcode"] as? String, rcode)
            XCTAssertEqual(rule["action"] as? String, "respond")
        }
        XCTAssertEqual(rules[3]["server"] as? String, "dns-1")
        XCTAssertEqual(rules[3]["timeout"] as? String, "3s")
        XCTAssertFalse(
            rules.contains { $0["domain_suffix"] != nil },
            "the global chain must apply to every query"
        )
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
            let probeChain = try XCTUnwrap(dns["rules"] as? [[String: Any]]).prefix(4).map { $0 }
            // Every probe rule is scoped to the probe domains; the chain ends in a terminal
            // route rule, so a probe lookup can never leak past it into a country rule.
            for rule in probeChain {
                XCTAssertEqual(rule["domain_suffix"] as? [String], ProbeTargets.ruleDomainSuffixes)
                if rule["match_response"] as? Bool != true {
                    XCTAssertEqual(rule["disable_cache"] as? Bool, true)
                    XCTAssertEqual(rule["disable_optimistic_cache"] as? Bool, true)
                }
            }
            XCTAssertEqual(probeChain[0]["action"] as? String, "evaluate")
            XCTAssertEqual(probeChain[0]["server"] as? String, "dns-0")
            // Nonce probes legitimately draw NXDOMAIN; the primary answering one must respond.
            XCTAssertEqual(probeChain[2]["response_rcode"] as? String, "NXDOMAIN")
            XCTAssertNil(probeChain[3]["action"])
            XCTAssertEqual(probeChain[3]["server"] as? String, "dns-1")

            // Resolve the pinned tags: the chain is only meaningful if the servers it names are
            // themselves DoH-through-proxy. This is the premise StartupPathVerificationTests
            // relies on for the cn shape (every probe flow proxied).
            let servers = try XCTUnwrap(dns["servers"] as? [[String: Any]])
            for tag in ["dns-0", "dns-1"] {
                let target = try XCTUnwrap(servers.first { $0["tag"] as? String == tag })
                XCTAssertEqual(target["type"] as? String, "https")
                XCTAssertEqual(target["detour"] as? String, "proxy")
            }
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
        // The /23 keeps the successor inside the prefix.
        XCTAssertEqual(SingBoxConfiguration.tunnelDnsAddress(for: "10.0.0.255/23"), "10.0.1.0")

        // sing-tun refuses to derive a hijack address whose successor escapes the TUN prefix
        // (HasNextAddress), so returning one here would fail every probe on a healthy tunnel:
        // the last address of a prefix must be rejected, exactly like a non-IPv4 input.
        for invalid in ["10.0.0.255/30", "172.19.0.3/30", "172.19.0.1", "fdfe:dcba:9876::1/126", "bogus/30"] {
            XCTAssertNil(SingBoxConfiguration.tunnelDnsAddress(for: invalid), invalid)
        }

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
        // The country rule must follow the 4-rule probe chain.
        let countryDnsIndex = dnsRules.firstIndex { $0["rule_set"] != nil }
        XCTAssertEqual(countryDnsIndex, 4)

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
