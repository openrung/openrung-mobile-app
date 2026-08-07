package com.openrung.net

import com.openrung.BuildConfig
import com.openrung.model.RelayConstants
import com.openrung.model.RelayDescriptor
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Split-tunneling emission input (split-tunnel spec §2). This is NOT the persisted config
 * ([com.openrung.vpn.SplitTunnelConfig]): the caller has already validated it — only countries
 * whose BOTH .srs files exist under [ruleSetDirectory] may appear in [bypassCountries], in
 * [SUPPORTED_COUNTRIES] order. Callers pass a null [SingBoxConfiguration.splitTunnel] when split
 * tunneling is disabled.
 */
data class SplitTunnelRules(
    val bypassLan: Boolean,
    val bypassCountries: List<String>,
    val excludedPackages: List<String>,
    /** Absolute directory containing `geosite-<cc>.srs` / `geoip-<cc>.srs`. */
    val ruleSetDirectory: String,
) {
    companion object {
        const val COUNTRY_IR = "ir"
        const val COUNTRY_CN = "cn"

        /** Countries with bundled rule sets, in the canonical emission order. */
        val SUPPORTED_COUNTRIES: List<String> = listOf(COUNTRY_IR, COUNTRY_CN)

        /** In-country public resolver bypassed domains resolve through over the direct path. */
        fun directDnsServer(country: String): String = when (country) {
            COUNTRY_IR -> "178.22.122.100" // Shecan
            COUNTRY_CN -> "223.5.5.5" // AliDNS
            else -> throw IllegalArgumentException("unsupported split-tunnel country: $country")
        }
    }
}

data class DnsOverHttpsResolver(
    val tag: String,
    /** Literal address keeps the resolver bootstrap independent from DNS itself. */
    val serverAddress: String,
    /** Hostname authenticated by TLS while [serverAddress] is dialed directly. */
    val tlsServerName: String,
)

data class SingBoxConfiguration(
    val relay: RelayDescriptor,
    /** Loopback TCP adapter exposed by a native transport. Empty means use the relay endpoint. */
    val bridgeHost: String = "",
    val bridgePort: Int = 0,
    val tunnelIPv4Address: String = "172.19.0.1/30",
    val tunnelIPv6Address: String = "fdfe:dcba:9876::1/126",
    val dnsOverHttpsResolvers: List<DnsOverHttpsResolver> = DEFAULT_DOH_RESOLVERS,
    val mtu: Int = 1400,
    val splitTunnel: SplitTunnelRules? = null,
) {
    fun encodedJsonString(): String {
        validateRelay()
        return prettyJson.encodeToString(makeJsonObject())
    }

    fun makeJsonObject(): JsonObject {
        require(mtu > 0) { "mtu must be positive" }
        validateRelay()
        val useLoopbackAdapter = bridgeHost.isNotBlank() || bridgePort != 0
        if (useLoopbackAdapter) {
            require(bridgeHost.isNotBlank() && bridgePort in 1..65535) {
                "loopback adapter requires a host and valid port"
            }
        }
        val outboundHost = if (useLoopbackAdapter) bridgeHost else relay.publicHost
        val outboundPort = if (useLoopbackAdapter) bridgePort else relay.publicPort
        val bypassCountries = splitTunnel?.bypassCountries.orEmpty()
        val excludedPackages = splitTunnel?.excludedPackages.orEmpty()
        validateDnsResolvers()
        val primaryDnsResolver = dnsOverHttpsResolvers.first()
        val fallbackDnsResolver = dnsOverHttpsResolvers.last()

        val tunInbound = mutableMapOf<String, JsonElement>(
            "type" to JsonPrimitive("tun"),
            "tag" to JsonPrimitive("tun-in"),
            "address" to JsonArray(listOf(JsonPrimitive(tunnelIPv4Address), JsonPrimitive(tunnelIPv6Address))),
            "mtu" to JsonPrimitive(mtu),
            "auto_route" to JsonPrimitive(true),
            "strict_route" to JsonPrimitive(true),
            "stack" to JsonPrimitive("system"),
            "dns_mode" to JsonPrimitive("hijack"),
            "endpoint_independent_nat" to JsonPrimitive(true),
        )
        if (excludedPackages.isNotEmpty()) {
            // Excluded apps leave the VPN at the OS level. NEVER emit include_package alongside
            // this: Android forbids mixing the two, and we only ever exclude.
            tunInbound["exclude_package"] = JsonArray(excludedPackages.map(::JsonPrimitive))
        }
        if (!useLoopbackAdapter) {
            relayRouteExcludeAddress(relay.publicHost)?.let {
                tunInbound["route_exclude_address"] = JsonArray(listOf(JsonPrimitive(it)))
            }
        }

        return buildJsonObject {
            put("log", buildJsonObject {
                // "info" logs every flow and DNS query inside the Go engine; release builds
                // keep only warnings to stay off the per-connection hot path.
                put("level", if (BuildConfig.DEBUG) "info" else "warn")
                put("timestamp", true)
            })
            put("dns", buildJsonObject {
                put("servers", buildJsonArray {
                    // Resolve DoH without asking DNS how to reach DNS: each resolver dials a
                    // literal IP while TLS authenticates the provider hostname. WSS therefore
                    // carries ordinary HTTPS/443 instead of the blackholed TCP/53 it replaces.
                    dnsOverHttpsResolvers.forEach { resolver ->
                        add(buildJsonObject {
                            put("tag", resolver.tag)
                            put("type", "https")
                            put("server", resolver.serverAddress)
                            put("server_port", 443)
                            put("path", "/dns-query")
                            put("detour", "proxy")
                            put("tls", buildJsonObject {
                                put("enabled", true)
                                put("server_name", resolver.tlsServerName)
                            })
                        })
                    }
                    bypassCountries.forEach { country ->
                        add(buildJsonObject {
                            put("tag", "dns-direct-$country")
                            put("type", "udp")
                            put("server", SplitTunnelRules.directDnsServer(country))
                            // Modern UDP DNS servers use a direct dialer when detour is omitted.
                            // Detouring to our otherwise-empty tagged direct outbound is rejected
                            // during sing-box's Start stage ("detour to an empty direct outbound").
                        })
                    }
                })
                put("rules", buildJsonArray {
                    // These exact-host rules deliberately precede every country rule. The probe
                    // therefore cannot be captured by geosite-cn (or a future country list), and
                    // disabling both caches makes each health check exercise upstream DoH.
                    dnsFailoverRules(
                        domain = CONNECTIVITY_PROBE_HOST,
                        disableCache = true,
                        requireAddress = true,
                    ).forEach(::add)
                    bypassCountries.forEach { country ->
                        add(buildJsonObject {
                            put("rule_set", JsonArray(listOf(JsonPrimitive("geosite-$country"))))
                            put("action", "route")
                            put("server", "dns-direct-$country")
                        })
                    }
                    // A static primary `final` never consults a second resolver. Evaluate is
                    // non-terminal on an exchange error in the pinned sing-box 1.14+ engine; a
                    // usable response is returned by `respond`, otherwise the next resolver runs.
                    dnsFailoverRules().forEach(::add)
                })
                put("final", fallbackDnsResolver.tag)
                put("timeout", DNS_FALLBACK_TIMEOUT)
            })
            put("inbounds", JsonArray(listOf(JsonObject(tunInbound))))
            put("outbounds", buildJsonArray {
                add(buildJsonObject {
                    put("type", "vless")
                    put("tag", "proxy")
                    put("server", outboundHost)
                    put("server_port", outboundPort)
                    put("uuid", relay.clientId)
                    put("flow", relay.flow)
                    put("network", "tcp")
                    put("packet_encoding", "xudp")
                    put("tls", buildJsonObject {
                        put("enabled", true)
                        put("server_name", relay.serverName)
                        put("utls", buildJsonObject {
                            put("enabled", true)
                            put("fingerprint", "chrome")
                        })
                        put("reality", buildJsonObject {
                            put("enabled", true)
                            put("public_key", relay.realityPublicKey)
                            put("short_id", relay.shortId)
                        })
                    })
                })
                add(buildJsonObject {
                    put("type", "direct")
                    put("tag", "direct")
                })
                add(buildJsonObject {
                    put("type", "block")
                    put("tag", "block")
                })
            })
            put("route", buildJsonObject {
                put("auto_detect_interface", true)
                put("find_process", true)
                put("default_domain_resolver", primaryDnsResolver.tag)
                if (bypassCountries.isNotEmpty()) {
                    put("rule_set", buildJsonArray {
                        bypassCountries.forEach { country ->
                            add(localRuleSet("geosite-$country"))
                            add(localRuleSet("geoip-$country"))
                        }
                    })
                }
                put("rules", buildJsonArray {
                    add(buildJsonObject {
                        put("protocol", "dns")
                        put("action", "hijack-dns")
                    })
                    // Raw TUN connections arrive with an IP destination. Sniff first so both the
                    // exact probe exception and country geosite rules can inspect TLS/HTTP names.
                    add(buildJsonObject {
                        put("action", "sniff")
                    })
                    add(buildJsonObject {
                        put("domain", JsonArray(listOf(JsonPrimitive(CONNECTIVITY_PROBE_HOST))))
                        put("outbound", "proxy")
                    })
                    if (splitTunnel?.bypassLan == true) {
                        add(buildJsonObject {
                            put("ip_is_private", true)
                            put("outbound", "direct")
                        })
                    }
                    bypassCountries.forEach { country ->
                        add(buildJsonObject {
                            put(
                                "rule_set",
                                JsonArray(
                                    listOf(
                                        JsonPrimitive("geosite-$country"),
                                        JsonPrimitive("geoip-$country"),
                                    ),
                                ),
                            )
                            put("outbound", "direct")
                        })
                    }
                })
                put("final", "proxy")
            })
            put("experimental", buildJsonObject {
                // No external_controller is set, so nothing listens; an empty clash_api
                // block just turns on sing-box's traffic accounting, which feeds the
                // cumulative bytes_sent/bytes_received counters reported with session
                // telemetry (see TelemetryManager.updateTrafficCounters).
                put("clash_api", buildJsonObject { })
            })
        }
    }

    /**
     * Emits an ordered primary-to-secondary resolver chain using sing-box 1.14 DNS actions.
     * `NOERROR` (including NODATA) and authoritative `NXDOMAIN` are terminal for ordinary
     * lookups. The known-existing probe is stricter: its primary response is accepted only when
     * it contains an address. Timeouts, transport errors, SERVFAIL and REFUSED fall through.
     */
    private fun dnsFailoverRules(
        domain: String? = null,
        disableCache: Boolean = false,
        requireAddress: Boolean = false,
    ): List<JsonObject> = buildList {
        dnsOverHttpsResolvers.dropLast(1).forEach { resolver ->
            add(buildJsonObject {
                domain?.let {
                    put("domain", JsonArray(listOf(JsonPrimitive(it))))
                }
                put("action", "evaluate")
                put("server", resolver.tag)
                put("timeout", DNS_PRIMARY_TIMEOUT)
                if (disableCache) {
                    put("disable_cache", true)
                    put("disable_optimistic_cache", true)
                }
            })
            if (requireAddress) {
                add(buildJsonObject {
                    domain?.let {
                        put("domain", JsonArray(listOf(JsonPrimitive(it))))
                    }
                    put("match_response", true)
                    put("ip_accept_any", true)
                    put("action", "respond")
                })
            } else {
                listOf("NOERROR", "NXDOMAIN").forEach { responseCode ->
                    add(buildJsonObject {
                        domain?.let {
                            put("domain", JsonArray(listOf(JsonPrimitive(it))))
                        }
                        put("match_response", true)
                        put("response_rcode", responseCode)
                        put("action", "respond")
                    })
                }
            }
        }
        add(buildJsonObject {
            domain?.let {
                put("domain", JsonArray(listOf(JsonPrimitive(it))))
            }
            put("action", "route")
            put("server", dnsOverHttpsResolvers.last().tag)
            put("timeout", DNS_FALLBACK_TIMEOUT)
            if (disableCache) {
                put("disable_cache", true)
                put("disable_optimistic_cache", true)
            }
        })
    }

    private fun localRuleSet(tag: String): JsonObject = buildJsonObject {
        put("type", "local")
        put("tag", tag)
        put("format", "binary")
        put("path", "${checkNotNull(splitTunnel).ruleSetDirectory}/$tag.srs")
    }

    private fun validateRelay() {
        require(relay.relayProtocol == RelayConstants.PROTOCOL_VLESS_REALITY_VISION) {
            "relay protocol is not vless-reality-vision"
        }
        require(relay.flow == RelayConstants.FLOW_VISION) {
            "relay flow is not xtls-rprx-vision"
        }
        require(relay.exitMode == RelayConstants.EXIT_MODE_DIRECT) {
            "relay exit mode is not direct"
        }
        require(relay.publicHost.isNotBlank() && relay.publicPort > 0) {
            "relay is missing required connection fields"
        }
        require(relay.clientId.isNotBlank() && relay.realityPublicKey.isNotBlank()) {
            "relay is missing required Reality fields"
        }
        require(relay.shortId.isNotBlank() && relay.serverName.isNotBlank()) {
            "relay is missing required TLS fields"
        }
    }

    private fun validateDnsResolvers() {
        require(dnsOverHttpsResolvers.size >= 2) {
            "at least two DNS-over-HTTPS resolvers are required for failover"
        }
        require(dnsOverHttpsResolvers.map { it.tag }.distinct().size == dnsOverHttpsResolvers.size) {
            "DNS-over-HTTPS resolver tags must be unique"
        }
        dnsOverHttpsResolvers.forEach { resolver ->
            require(resolver.tag.isNotBlank() && resolver.tlsServerName.isNotBlank()) {
                "DNS-over-HTTPS resolver requires a tag and TLS server name"
            }
            val address = resolver.serverAddress.removePrefix("[").removeSuffix("]")
            require(address.isIPv4Literal() || address.contains(":")) {
                "DNS-over-HTTPS resolver bootstrap must be a literal IP address"
            }
        }
    }

    companion object {
        /** Exact host used only by startup and long-lived through-tunnel probes. */
        const val CONNECTIVITY_PROBE_HOST = "cp.cloudflare.com"

        val DEFAULT_DOH_RESOLVERS: List<DnsOverHttpsResolver> = listOf(
            DnsOverHttpsResolver(
                tag = "dns-proxy-primary",
                serverAddress = "1.1.1.1",
                tlsServerName = "cloudflare-dns.com",
            ),
            DnsOverHttpsResolver(
                tag = "dns-proxy-secondary",
                serverAddress = "8.8.8.8",
                tlsServerName = "dns.google",
            ),
        )

        private const val DNS_PRIMARY_TIMEOUT = "2s"
        private const val DNS_FALLBACK_TIMEOUT = "3s"

        private val prettyJson = Json {
            prettyPrint = true
        }

        fun relayRouteExcludeAddress(host: String): String? {
            val cleanHost = host.removePrefix("[").removeSuffix("]")
            return when {
                cleanHost.isIPv4Literal() -> "$cleanHost/32"
                cleanHost.contains(":") -> "$cleanHost/128"
                else -> null
            }
        }

        private fun String.isIPv4Literal(): Boolean {
            val octets = split(".")
            return octets.size == 4 && octets.all { octet ->
                val value = octet.toIntOrNull()
                value != null && value in 0..255 && value.toString() == octet
            }
        }
    }
}
