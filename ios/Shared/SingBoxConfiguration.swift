import Foundation

public struct SingBoxConfiguration: Equatable, Sendable {
    public struct DNSOverHTTPSResolver: Equatable, Sendable {
        public let tag: String
        public let serverAddress: String
        public let tlsServerName: String

        public init(tag: String, serverAddress: String, tlsServerName: String) {
            self.tag = tag
            self.serverAddress = serverAddress
            self.tlsServerName = tlsServerName
        }
    }

    /// A hostname used only to prove that the active tunnel can resolve DNS and complete HTTPS.
    /// It must stay out of country-bypass routing even if a downloaded geosite rule later grows
    /// to include it.
    public static let connectivityProbeHost = "cp.cloudflare.com"

    public static let defaultDNSOverHTTPSResolvers = [
        DNSOverHTTPSResolver(
            tag: "dns-proxy-primary",
            serverAddress: "1.1.1.1",
            tlsServerName: "cloudflare-dns.com"
        ),
        DNSOverHTTPSResolver(
            tag: "dns-proxy-secondary",
            serverAddress: "8.8.8.8",
            tlsServerName: "dns.google"
        ),
    ]

    public let relay: RelayDescriptor
    public let tunnelIPv4Address: String
    public let tunnelIPv6Address: String
    public let dnsOverHTTPSResolvers: [DNSOverHTTPSResolver]
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
        tunnelIPv4Address: String = "172.19.0.1/30",
        tunnelIPv6Address: String = "fdfe:dcba:9876::1/126",
        dnsOverHTTPSResolvers: [DNSOverHTTPSResolver] = Self.defaultDNSOverHTTPSResolvers,
        mtu: Int = 1400,
        bridgeHost: String? = nil,
        bridgePort: Int? = nil,
        splitTunnel: SplitTunnelRules? = nil
    ) {
        self.relay = relay
        self.tunnelIPv4Address = tunnelIPv4Address
        self.tunnelIPv6Address = tunnelIPv6Address
        self.dnsOverHTTPSResolvers = dnsOverHTTPSResolvers
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

        // Resolve DoH without asking DNS how to reach DNS: each resolver dials a literal IP while
        // TLS still authenticates and sends the provider hostname. Both exchanges use the proxy,
        // so WSS carries ordinary HTTPS/443 instead of the blackholed TCP/53 traffic it replaced.
        let proxiedResolvers = dnsOverHTTPSResolvers.count >= 2
            ? Array(dnsOverHTTPSResolvers.prefix(2))
            : Self.defaultDNSOverHTTPSResolvers
        let primaryDNS = proxiedResolvers[0].tag
        let secondaryDNS = proxiedResolvers[1].tag
        var dnsServerObjects: [[String: Any]] = proxiedResolvers.map { resolver in
            [
                "tag": resolver.tag,
                "type": "https",
                "server": resolver.serverAddress,
                "server_port": 443,
                "path": "/dns-query",
                "detour": "proxy",
                "tls": [
                    "enabled": true,
                    "server_name": resolver.tlsServerName,
                ] as [String: Any],
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
        // `final` by itself never retries another resolver. An evaluate action is deliberately
        // non-terminal: a usable primary response is returned by a following respond rule, while
        // an exchange error or unusable response falls through to the secondary. The known probe
        // host requires at least one address; NXDOMAIN, SERVFAIL and empty NOERROR all fail over.
        // The exact-host rules run first and disable both normal and optimistic caches so every
        // startup/health HTTPS probe also exercises a fresh upstream DNS exchange.
        var dnsRules: [[String: Any]] = [
            [
                "domain": [Self.connectivityProbeHost],
                "action": "evaluate",
                "server": primaryDNS,
                "timeout": "2s",
                "disable_cache": true,
                "disable_optimistic_cache": true,
            ],
            [
                "domain": [Self.connectivityProbeHost],
                "match_response": true,
                "ip_accept_any": true,
                "action": "respond",
            ],
            [
                "domain": [Self.connectivityProbeHost],
                "action": "route",
                "server": secondaryDNS,
                "timeout": "3s",
                "disable_cache": true,
                "disable_optimistic_cache": true,
            ],
        ]
        if bypassCountries.isEmpty == false {
            dnsRules.append(contentsOf: bypassCountries.map { country in
                [
                    "rule_set": [country.geositeTag],
                    "action": "route",
                    "server": "dns-direct-\(country.code)"
                ] as [String: Any]
            })
        }
        dnsRules.append([
            "action": "evaluate",
            "server": primaryDNS,
            "timeout": "2s",
        ])
        dnsRules.append([
            "match_response": true,
            "response_rcode": "NOERROR",
            "action": "respond",
        ])
        dnsRules.append([
            "match_response": true,
            "response_rcode": "NXDOMAIN",
            "action": "respond",
        ])
        dnsRules.append([
            "action": "route",
            "server": secondaryDNS,
            "timeout": "3s",
        ])
        let dns: [String: Any] = [
            "servers": dnsServerObjects,
            "rules": dnsRules,
            "final": secondaryDNS,
            "timeout": "3s",
        ]

        var routeRules: [[String: Any]] = [
            [
                "protocol": "dns",
                "action": "hijack-dns"
            ],
            // Sniff before applying the exact-host exception: packets arrive from the TUN with an
            // IP destination, so country geosite matching and this anti-bypass rule both need the
            // recovered TLS/HTTP hostname.
            ["action": "sniff"],
            [
                "domain": [Self.connectivityProbeHost],
                "outbound": "proxy",
            ],
        ]
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
            "default_domain_resolver": primaryDNS,
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
