import Foundation

public struct SingBoxConfiguration: Equatable, Sendable {
    /// DoH-capable public resolvers reached as IP literals: no bootstrap resolution needed.
    public static let defaultDoHResolvers = ["1.1.1.1", "8.8.8.8"]

    /// Hostnames the DoH TLS handshakes authenticate while dialing the IP literals above.
    private static let dohTLSServerNames = [
        "1.1.1.1": "cloudflare-dns.com",
        "8.8.8.8": "dns.google",
    ]

    // Per-evaluate budget before the next resolver runs, and the terminal/global budget.
    public static let dnsPrimaryTimeoutMilliseconds: UInt64 = 2_000
    public static let dnsFallbackTimeoutMilliseconds: UInt64 = 3_000
    private static let dnsPrimaryTimeout = "\(dnsPrimaryTimeoutMilliseconds / 1_000)s"
    private static let dnsFallbackTimeout = "\(dnsFallbackTimeoutMilliseconds / 1_000)s"

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
    /// carries no explicit `dns_address` (we emit none), sing-tun derives the hijack address as
    /// the next address after the TUN's own IPv4 address, and the tun inbound tags a packet
    /// `Protocol=DNS` only when its destination equals that address — after which the router
    /// hijacks it into the DNS module ahead of any route rule. A datagram addressed to a public
    /// resolver (1.1.1.1) is NOT tagged, matches no rule, and dies on the TCP-only proxy
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
    /// build without split tunneling). Mirrors the Kotlin generator, except iOS NEVER emits
    /// `exclude_package` — per-app exclusion is Android-only.
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

    public func encodedJSON() throws -> Data {
        try JSONSerialization.data(
            withJSONObject: makeJSONObject(),
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    public func encodedJSONString() throws -> String {
        String(decoding: try encodedJSON(), as: UTF8.self)
    }

    public func makeJSONObject() -> [String: Any] {
        var tunInbound: [String: Any] = [
            "type": "tun",
            "tag": "tun-in",
            "address": [
                tunnelIPv4Address,
                tunnelIPv6Address
            ],
            "mtu": mtu,
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
            "dns_mode": "hijack",
            "endpoint_independent_nat": true
        ]
        // A native bridge owns its outer socket. Only a direct Reality socket needs the raw relay
        // address excluded from the TUN route; the inner bridge endpoint must stay on loopback.
        if bridgeHost == nil, let excludeAddress = Self.relayRouteExcludeAddress(for: relay.publicHost) {
            tunInbound["route_exclude_address"] = [excludeAddress]
        }

        let outboundHost = bridgeHost ?? relay.publicHost
        let outboundPort = bridgePort ?? relay.publicPort

        // Split-tunnel emission (spec §2): countries were already validated (files on disk) and
        // normalized to ir,cn order by the caller; unknown codes are dropped here as a last resort.
        let bypassCountries = (splitTunnel?.bypassCountries ?? []).compactMap(SplitTunnelCountry.forCode)
        let bypassLan = splitTunnel?.bypassLan == true

        let dnsServers = Self.defaultDoHResolvers
        var dnsServerObjects: [[String: Any]] = dnsServers.enumerated().map { index, server in
            var object: [String: Any] = [
                "tag": "dns-\(index)",
                // DoH over 443 via the proxy: relays answer 443 on every transport, while
                // TCP/53 gets no replies under WSS. IP-literal servers need no bootstrap
                // resolver (defaults: port 443, path /dns-query).
                "type": "https",
                "server": server,
                "detour": "proxy"
            ]
            // TLS authenticates the provider hostname while the dial stays on the IP literal,
            // so a provider dropping IP SANs from its certificate cannot break resolution.
            if let serverName = Self.dohTLSServerNames[server] {
                object["tls"] = ["enabled": true, "server_name": serverName] as [String: Any]
            }
            return object
        }
        for country in bypassCountries {
            // A DNS server with no detour builds its own direct dialer, which is exactly what a
            // bypass resolver needs. Detouring to our otherwise-empty tagged direct outbound is
            // rejected during sing-box's Start stage. DoH over 443 keeps the query encrypted on
            // that direct path, and 443 survives the middleboxes that a bare 853 often does not.
            guard let resolver = country.directResolver else { continue }
            dnsServerObjects.append([
                "tag": "dns-direct-\(country.code)",
                "type": "https",
                "server": resolver.server,
                "tls": ["enabled": true, "server_name": resolver.tlsServerName] as [String: Any]
            ])
        }
        // Highest priority: probe lookups must reach the proxied DoH resolvers even when a
        // country rule would divert them (geosite-cn contains gstatic-class hosts), and must
        // never be answered from any cache — a cached answer proves nothing about the tunnel
        // right now. The chain is terminal for probe domains (its trailing route rule always
        // fires), so a future geosite refresh can never capture a probe lookup.
        var dnsRules = dnsFailoverRules(
            domainSuffixes: ProbeTargets.ruleDomainSuffixes,
            disableCache: true
        )
        dnsRules.append(contentsOf: bypassCountries.flatMap { Self.countryDnsRules(for: $0) })
        // Real failover for everything else: a static `final` would never consult a second
        // resolver. `evaluate` is non-terminal on a transport error, timeout, SERVFAIL or
        // REFUSED in the pinned engine — a usable answer (NOERROR, or an authoritative
        // NXDOMAIN) is returned by `respond`, anything else falls through to the next
        // resolver's terminal route rule.
        dnsRules.append(contentsOf: dnsFailoverRules(domainSuffixes: nil, disableCache: false))
        let dns: [String: Any] = [
            "servers": dnsServerObjects,
            "rules": dnsRules,
            "final": "dns-\(dnsServers.count - 1)",
            "timeout": Self.dnsFallbackTimeout
        ]

        var routeRules: [[String: Any]] = [
            [
                "protocol": "dns",
                "action": "hijack-dns"
            ]
        ]
        if bypassCountries.isEmpty == false {
            // Domain rule sets need the sniffed hostname on raw connections.
            routeRules.append(["action": "sniff"])
            // Probe traffic must reach the proxy even when a bypass rule would send it direct;
            // a probe that escapes onto the direct path can report CONNECTED over a dead
            // tunnel. Must precede every bypass rule.
            routeRules.append([
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "outbound": "proxy"
            ])
        }
        if bypassLan {
            routeRules.append([
                "ip_is_private": true,
                "outbound": "direct"
            ])
        }
        for country in bypassCountries {
            routeRules.append([
                "rule_set": [country.geositeTag, country.geoipTag],
                "outbound": "direct"
            ])
        }
        var route: [String: Any] = [
            "auto_detect_interface": true,
            "default_domain_resolver": "dns-0",
            "rules": routeRules,
            "final": "proxy"
        ]
        if bypassCountries.isEmpty == false, let ruleSetDirectory = splitTunnel?.ruleSetDirectory {
            route["rule_set"] = bypassCountries.flatMap { country in
                [
                    [
                        "type": "local",
                        "tag": country.geositeTag,
                        "format": "binary",
                        "path": "\(ruleSetDirectory)/\(country.geositeTag).srs"
                    ],
                    [
                        "type": "local",
                        "tag": country.geoipTag,
                        "format": "binary",
                        "path": "\(ruleSetDirectory)/\(country.geoipTag).srs"
                    ]
                ] as [[String: Any]]
            }
        }

        // "info" logs every flow and DNS query — each line crosses the gomobile boundary and
        // costs CPU inside the 50 MB extension, so release builds keep only warnings.
        #if DEBUG
        let logLevel = "info"
        #else
        let logLevel = "warn"
        #endif

        return [
            "log": [
                "level": logLevel,
                "timestamp": true
            ],
            "dns": dns,
            "inbounds": [
                tunInbound
            ],
            "outbounds": [
                [
                    "type": "vless",
                    "tag": "proxy",
                    "server": outboundHost,
                    "server_port": outboundPort,
                    "uuid": relay.clientID,
                    "flow": relay.flow,
                    "network": "tcp",
                    "packet_encoding": "xudp",
                    "tls": [
                        "enabled": true,
                        "server_name": relay.serverName,
                        "utls": [
                            "enabled": true,
                            "fingerprint": "chrome"
                        ],
                        "reality": [
                            "enabled": true,
                            "public_key": relay.realityPublicKey,
                            "short_id": relay.shortID
                        ]
                    ] as [String: Any]
                ] as [String: Any],
                [
                    "type": "direct",
                    "tag": "direct"
                ],
                [
                    "type": "block",
                    "tag": "block"
                ]
            ],
            "route": route,
            "experimental": [
                // No external_controller is set, so nothing listens; an empty clash_api
                // block just turns on sing-box's traffic accounting, which feeds the
                // cumulative bytes_sent/bytes_received counters reported with session
                // telemetry (see TelemetryManager.updateTrafficCounters).
                "clash_api": [String: Any]()
            ]
        ]
    }

    /// Per-country lookup chain for the domains that country bypasses: ask the in-country DoH
    /// resolver, and return its answer when it is a real one (NOERROR, or an authoritative
    /// NXDOMAIN). Nothing else is terminal, so a resolver that is unreachable, times out, or has
    /// let its certificate lapse falls through to the proxied global chain below instead of
    /// failing the lookup outright — the same fail-open posture as the rest of the feature
    /// (CONTRACT §1), and the reason moving off plaintext UDP cannot cost anyone reachability.
    ///
    /// `rule_set` matches against the queried domain in both the query and the response pass, so
    /// the response rules stay scoped to this country's domains.
    ///
    /// Empty for a country with no usable in-country resolver: with nothing to evaluate, its
    /// lookups simply reach the global chain, which is where they would end up anyway.
    private static func countryDnsRules(for country: SplitTunnelCountry) -> [[String: Any]] {
        guard country.directResolver != nil else { return [] }
        var rules: [[String: Any]] = [
            [
                "rule_set": [country.geositeTag],
                "action": "evaluate",
                "server": "dns-direct-\(country.code)",
                "timeout": dnsPrimaryTimeout
            ]
        ]
        for rcode in ["NOERROR", "NXDOMAIN"] {
            rules.append([
                "rule_set": [country.geositeTag],
                "match_response": true,
                "response_rcode": rcode,
                "action": "respond"
            ])
        }
        return rules
    }

    /// Emits an ordered primary-to-fallback resolver chain from sing-box 1.14 DNS rule actions:
    /// for every resolver but the last, `evaluate` exchanges the query (non-terminal on error)
    /// and `respond` returns its answer when the RCODE is NOERROR or NXDOMAIN — both are real
    /// answers, and probe nonce queries are expected to draw NXDOMAIN. Everything else (timeout,
    /// transport error, SERVFAIL, REFUSED) falls through until the last resolver's terminal
    /// route rule. With `domainSuffixes` the whole chain applies only to those domains and is
    /// guaranteed terminal for them; with nil it applies to every remaining query.
    private func dnsFailoverRules(
        domainSuffixes: [String]?,
        disableCache: Bool
    ) -> [[String: Any]] {
        let dnsServers = Self.defaultDoHResolvers
        var rules: [[String: Any]] = []
        for index in 0..<(dnsServers.count - 1) {
            var evaluate: [String: Any] = [
                "action": "evaluate",
                "server": "dns-\(index)",
                "timeout": Self.dnsPrimaryTimeout
            ]
            if let domainSuffixes { evaluate["domain_suffix"] = domainSuffixes }
            if disableCache {
                evaluate["disable_cache"] = true
                evaluate["disable_optimistic_cache"] = true
            }
            rules.append(evaluate)
            for rcode in ["NOERROR", "NXDOMAIN"] {
                var respond: [String: Any] = [
                    "match_response": true,
                    "response_rcode": rcode,
                    "action": "respond"
                ]
                if let domainSuffixes { respond["domain_suffix"] = domainSuffixes }
                rules.append(respond)
            }
        }
        var route: [String: Any] = [
            "server": "dns-\(dnsServers.count - 1)",
            "timeout": Self.dnsFallbackTimeout
        ]
        if let domainSuffixes { route["domain_suffix"] = domainSuffixes }
        if disableCache {
            route["disable_cache"] = true
            route["disable_optimistic_cache"] = true
        }
        rules.append(route)
        return rules
    }

    private static func relayRouteExcludeAddress(for host: String) -> String? {
        let cleanHost = host.removingIPv6Brackets()
        if cleanHost.isIPv4Literal {
            return "\(cleanHost)/32"
        }
        if cleanHost.contains(":") {
            return "\(cleanHost)/128"
        }
        return nil
    }
}

private extension String {
    func removingIPv6Brackets() -> String {
        guard hasPrefix("["), hasSuffix("]") else {
            return self
        }
        return String(dropFirst().dropLast())
    }

    var isIPv4Literal: Bool {
        let octets = split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else {
            return false
        }
        return octets.allSatisfy { octet in
            guard let value = Int(octet), (0...255).contains(value) else {
                return false
            }
            return String(value) == String(octet)
        }
    }
}
