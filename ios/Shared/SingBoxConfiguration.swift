import Foundation

public struct SingBoxConfiguration: Equatable, Sendable {
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
    public static let defaultTunnelDnsAddress = tunnelDnsAddress(for: defaultTunnelIPv4Address)

    /// Next IPv4 address after `tunnelIPv4Address`, mirroring sing-tun's derivation.
    public static func tunnelDnsAddress(for tunnelIPv4Address: String) -> String {
        let octets = tunnelIPv4Address.split(separator: "/")[0].split(separator: ".")
        precondition(octets.count == 4, "tunnel address is not IPv4: \(tunnelIPv4Address)")
        let value = octets.reduce(UInt32(0)) { accumulated, octet in
            guard let part = UInt32(octet), part <= 255 else {
                preconditionFailure("tunnel address is not IPv4: \(tunnelIPv4Address)")
            }
            return accumulated << 8 | part
        }
        let next = value &+ 1
        return [24, 16, 8, 0].map { String((next >> UInt32($0)) & 0xFF) }.joined(separator: ".")
    }

    public let relay: RelayDescriptor
    public let tunnelIPv4Address: String
    public let tunnelIPv6Address: String
    public let dnsServers: [String]
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
        // DoH resolver IPs in priority order; index 0 is emitted as the final `dns-0` server.
        dnsServers: [String] = DnsResolverRotation.defaultResolvers,
        mtu: Int = 1400,
        bridgeHost: String? = nil,
        bridgePort: Int? = nil,
        splitTunnel: SplitTunnelRules? = nil
    ) {
        self.relay = relay
        self.tunnelIPv4Address = tunnelIPv4Address
        self.tunnelIPv6Address = tunnelIPv6Address
        self.dnsServers = dnsServers
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

        var dnsServerObjects: [[String: Any]] = dnsServers.enumerated().map { index, server in
            [
                "tag": "dns-\(index)",
                // DoH over 443 via the proxy: relays answer 443 on every transport, while
                // TCP/53 gets no replies under WSS. IP-literal servers need no bootstrap
                // resolver (defaults: port 443, path /dns-query).
                "type": "https",
                "server": server,
                "detour": "proxy"
            ]
        }
        for country in bypassCountries {
            // Modern UDP DNS servers use a direct dialer when detour is omitted. Detouring to our
            // otherwise-empty tagged direct outbound is rejected during sing-box's Start stage.
            dnsServerObjects.append([
                "tag": "dns-direct-\(country.code)",
                "type": "udp",
                "server": country.directResolver
            ])
        }
        // Highest priority: probe lookups must reach the proxied DoH resolver even when a
        // country rule would divert them (geosite-cn contains gstatic-class hosts), and must
        // never be answered from the engine cache — a cached answer proves nothing about the
        // tunnel right now.
        var dnsRules: [[String: Any]] = [
            [
                "domain_suffix": ProbeTargets.ruleDomainSuffixes,
                "server": "dns-0",
                "disable_cache": true
            ]
        ]
        dnsRules.append(contentsOf: bypassCountries.map { country in
            [
                "rule_set": [country.geositeTag],
                "server": "dns-direct-\(country.code)"
            ] as [String: Any]
        })
        let dns: [String: Any] = [
            "servers": dnsServerObjects,
            "rules": dnsRules,
            "final": "dns-0"
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
