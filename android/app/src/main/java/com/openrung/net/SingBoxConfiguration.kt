package com.openrung.net

import com.openrung.BuildConfig
import com.openrung.model.RelayConstants
import com.openrung.model.RelayDescriptor
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonObjectBuilder
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

        /**
         * An in-country public resolver reached over the DIRECT path, so bypassed domains resolve
         * to in-country CDN nodes instead of the relay exit's view of them.
         *
         * DoH over 443, never plaintext UDP/53: these queries leave the device on the user's real
         * IP while the tunnel is up, so the local network, the ISP and anything else on the path
         * must not get a cleartext list of the domains being bypassed (nor the chance to forge the
         * answers). [server] stays an IP literal so no bootstrap lookup is needed, and TLS
         * authenticates [tlsServerName] — the same shape the proxied DoH resolvers use.
         */
        data class DirectResolver(val server: String, val tlsServerName: String)

        /**
         * Null when the country has no encrypted public resolver we can currently stand behind.
         * Its bypass then keeps its ROUTE rules — the traffic still takes the direct path — and
         * only its lookups fall to the proxied DoH chain, resolving through the relay exit's view.
         * That costs in-country CDN affinity and nothing else.
         *
         * A resolver goes in here only while its certificate actually validates. Anything else is
         * worse than omitting it: sing-box would spend the full evaluate timeout failing the TLS
         * handshake on EVERY bypassed lookup before the fallback runs, so users would pay latency
         * for an in-country answer they can never receive. Never restore one on the strength of
         * its documentation — verify the live endpoint first.
         */
        fun directResolver(country: String): DirectResolver? = when (country) {
            // Shecan is Iran's usual public resolver, but every endpoint it publishes
            // (178.22.122.100, 185.51.200.2, dns.shecan.ir) served an expired Let's Encrypt
            // certificate as of 2026-08-12 (notAfter Jul 10 2026), on both 443 and 853. Electro
            // (78.157.42.100) refuses both ports and Begzar's DoH host no longer resolves, so
            // Iran has no verifiable encrypted resolver to point at right now.
            COUNTRY_IR -> null
            // AliDNS (Chinese public resolver); https://223.5.5.5/dns-query is a published
            // endpoint and its certificate covers the IP literal.
            COUNTRY_CN -> DirectResolver("223.5.5.5", "dns.alidns.com")
            else -> throw IllegalArgumentException("unsupported split-tunnel country: $country")
        }
    }
}

data class SingBoxConfiguration(
    val relay: RelayDescriptor,
    /** Loopback TCP adapter exposed by a native transport. Empty means use the relay endpoint. */
    val bridgeHost: String = "",
    val bridgePort: Int = 0,
    val tunnelIPv4Address: String = DEFAULT_TUNNEL_IPV4_ADDRESS,
    val tunnelIPv6Address: String = "fdfe:dcba:9876::1/126",
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
        val dnsServers = DEFAULT_DOH_RESOLVERS

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
                    dnsServers.forEachIndexed { index, server ->
                        add(buildJsonObject {
                            put("tag", "dns-$index")
                            // DoH over 443 via the proxy: relays answer 443 on every transport,
                            // while TCP/53 gets no replies under WSS. IP-literal servers need no
                            // bootstrap resolver (defaults: port 443, path /dns-query).
                            put("type", "https")
                            put("server", server)
                            put("detour", "proxy")
                            // TLS authenticates the provider hostname while the dial stays on
                            // the IP literal, so a provider dropping IP SANs from its
                            // certificate cannot break resolution.
                            DOH_TLS_SERVER_NAMES[server]?.let { serverName ->
                                put("tls", buildJsonObject {
                                    put("enabled", true)
                                    put("server_name", serverName)
                                })
                            }
                        })
                    }
                    bypassCountries.forEach { country ->
                        val resolver = SplitTunnelRules.directResolver(country) ?: return@forEach
                        add(buildJsonObject {
                            put("tag", "dns-direct-$country")
                            // DoH over 443 on the direct path: encrypted, and 443 survives the
                            // middleboxes that a bare 853 often does not.
                            put("type", "https")
                            put("server", resolver.server)
                            put("tls", buildJsonObject {
                                put("enabled", true)
                                put("server_name", resolver.tlsServerName)
                            })
                            // A DNS server with no detour builds its own direct dialer, which is
                            // exactly what a bypass resolver needs. Detouring to our otherwise-empty
                            // tagged direct outbound is rejected during sing-box's Start stage
                            // ("detour to an empty direct outbound").
                        })
                    }
                })
                put("rules", buildJsonArray {
                    // Highest priority: probe lookups must reach the proxied DoH resolvers even
                    // when a country rule would divert them (geosite-cn contains gstatic-class
                    // hosts), and must never be answered from any cache — a cached answer
                    // proves nothing about the tunnel right now. The chain is terminal for
                    // probe domains (its trailing route rule always fires), so a future geosite
                    // refresh can never capture a probe lookup.
                    dnsFailoverRules(
                        domainSuffixes = ProbeTargets.RULE_DOMAIN_SUFFIXES,
                        disableCache = true,
                    ).forEach(::add)
                    bypassCountries.forEach { country ->
                        countryDnsRules(country).forEach(::add)
                    }
                    // Real failover for everything else: a static `final` would never consult a
                    // second resolver. `evaluate` is non-terminal on a transport error, timeout,
                    // SERVFAIL or REFUSED in the pinned engine — a usable answer (NOERROR, or an
                    // authoritative NXDOMAIN) is returned by `respond`, anything else falls
                    // through to the next resolver's terminal route rule.
                    dnsFailoverRules(domainSuffixes = null, disableCache = false).forEach(::add)
                })
                put("final", "dns-${dnsServers.lastIndex}")
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
                put("default_domain_resolver", "dns-0")
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
                    if (bypassCountries.isNotEmpty()) {
                        // Route rules need a sniffed domain before geosite matching can work.
                        add(buildJsonObject {
                            put("action", "sniff")
                        })
                        // Probe traffic must reach the proxy even when a bypass rule would send
                        // it direct; a probe that escapes onto the direct path can report
                        // CONNECTED over a dead tunnel. Must precede every bypass rule.
                        add(buildJsonObject {
                            put(
                                "domain_suffix",
                                JsonArray(ProbeTargets.RULE_DOMAIN_SUFFIXES.map(::JsonPrimitive)),
                            )
                            put("outbound", "proxy")
                        })
                    }
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
     * Emits an ordered primary-to-fallback resolver chain from sing-box 1.14 DNS rule actions:
     * for every resolver but the last, `evaluate` exchanges the query (non-terminal on error)
     * and `respond` returns its answer when the RCODE is NOERROR or NXDOMAIN — both are real
     * answers, and probe nonce queries are expected to draw NXDOMAIN. Everything else (timeout,
     * transport error, SERVFAIL, REFUSED) falls through until the last resolver's terminal
     * route rule. With [domainSuffixes] the whole chain applies only to those domains and is
     * guaranteed terminal for them; with null it applies to every remaining query.
     */
    private fun dnsFailoverRules(
        domainSuffixes: List<String>?,
        disableCache: Boolean,
    ): List<JsonObject> = buildList {
        val dnsServers = DEFAULT_DOH_RESOLVERS
        fun JsonObjectBuilder.putScopeAndCache() {
            domainSuffixes?.let {
                put("domain_suffix", JsonArray(it.map(::JsonPrimitive)))
            }
            if (disableCache) {
                put("disable_cache", true)
                put("disable_optimistic_cache", true)
            }
        }
        dnsServers.dropLast(1).forEachIndexed { index, _ ->
            add(buildJsonObject {
                putScopeAndCache()
                put("action", "evaluate")
                put("server", "dns-$index")
                put("timeout", DNS_PRIMARY_TIMEOUT)
            })
            listOf("NOERROR", "NXDOMAIN").forEach { rcode ->
                add(buildJsonObject {
                    domainSuffixes?.let {
                        put("domain_suffix", JsonArray(it.map(::JsonPrimitive)))
                    }
                    put("match_response", true)
                    put("response_rcode", rcode)
                    put("action", "respond")
                })
            }
        }
        add(buildJsonObject {
            putScopeAndCache()
            put("server", "dns-${dnsServers.lastIndex}")
            put("timeout", DNS_FALLBACK_TIMEOUT)
        })
    }

    /**
     * Per-country lookup chain for the domains that country bypasses: ask the in-country DoH
     * resolver, and return its answer when it is a real one (NOERROR, or an authoritative
     * NXDOMAIN). Nothing else is terminal, so a resolver that is unreachable, times out, or has
     * let its certificate lapse falls through to the proxied global chain below instead of
     * failing the lookup outright — the same fail-open posture as the rest of the feature
     * (CONTRACT §1), and the reason moving off plaintext UDP cannot cost anyone reachability.
     *
     * `rule_set` matches against the queried domain in both the query and the response pass, so
     * the response rules stay scoped to this country's domains.
     *
     * Empty for a country with no usable in-country resolver: with nothing to evaluate, its
     * lookups simply reach the global chain, which is where they would end up anyway.
     */
    private fun countryDnsRules(country: String): List<JsonObject> = buildList {
        if (SplitTunnelRules.directResolver(country) == null) return@buildList
        val ruleSet = JsonArray(listOf(JsonPrimitive("geosite-$country")))
        add(buildJsonObject {
            put("rule_set", ruleSet)
            put("action", "evaluate")
            put("server", "dns-direct-$country")
            put("timeout", DNS_PRIMARY_TIMEOUT)
        })
        listOf("NOERROR", "NXDOMAIN").forEach { rcode ->
            add(buildJsonObject {
                put("rule_set", ruleSet)
                put("match_response", true)
                put("response_rcode", rcode)
                put("action", "respond")
            })
        }
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

    companion object {
        private val prettyJson = Json {
            prettyPrint = true
        }

        /** DoH-capable public resolvers reached as IP literals: no bootstrap resolution needed. */
        val DEFAULT_DOH_RESOLVERS = listOf("1.1.1.1", "8.8.8.8")

        /** Hostnames the DoH TLS handshakes authenticate while dialing the IP literals above. */
        private val DOH_TLS_SERVER_NAMES = mapOf(
            "1.1.1.1" to "cloudflare-dns.com",
            "8.8.8.8" to "dns.google",
        )

        // Per-evaluate budget before the next resolver runs, and the terminal/global budget.
        const val DNS_PRIMARY_TIMEOUT_MS = 2_000L
        const val DNS_FALLBACK_TIMEOUT_MS = 3_000L
        private val DNS_PRIMARY_TIMEOUT = "${DNS_PRIMARY_TIMEOUT_MS / 1_000}s"
        private val DNS_FALLBACK_TIMEOUT = "${DNS_FALLBACK_TIMEOUT_MS / 1_000}s"

        /**
         * Engine-side worst case for one lookup through the default chain: every non-terminal
         * resolver may consume its full evaluate timeout before the terminal fallback gets its
         * own. Probe budgets are derived from this (see [DnsProbe]) so they can never again
         * abort an attempt while the chain is still legitimately working.
         */
        val DNS_FAILOVER_WORST_CASE_MS =
            (DEFAULT_DOH_RESOLVERS.size - 1) * DNS_PRIMARY_TIMEOUT_MS + DNS_FALLBACK_TIMEOUT_MS

        /** Default TUN IPv4 address; the DNS address below is derived from it. */
        const val DEFAULT_TUNNEL_IPV4_ADDRESS = "172.19.0.1/30"

        /**
         * The ONLY in-TUN address whose port-53 traffic sing-box hijacks. When the tun inbound
         * carries no explicit `dns_address` (we emit none), sing-tun derives the hijack address
         * as the next address after the TUN's own IPv4 address, and the tun inbound tags a
         * packet `Protocol=DNS` only when its destination equals that address — after which the
         * router hijacks it into the DNS module ahead of any route rule. A datagram addressed
         * to a public resolver (1.1.1.1) is NOT tagged, matches no rule, and dies on the
         * TCP-only proxy outbound, so the fresh-DNS probe must target this address.
         */
        val DEFAULT_TUNNEL_DNS_ADDRESS = tunnelDnsAddress(DEFAULT_TUNNEL_IPV4_ADDRESS)

        /** Next IPv4 address after [tunnelIPv4Address], mirroring sing-tun's derivation. */
        fun tunnelDnsAddress(tunnelIPv4Address: String): String {
            val octets = tunnelIPv4Address.substringBefore("/").split(".")
            require(octets.size == 4) { "tunnel address is not IPv4: $tunnelIPv4Address" }
            val value = octets.fold(0L) { acc, octet ->
                val part = requireNotNull(octet.toIntOrNull()) {
                    "tunnel address is not IPv4: $tunnelIPv4Address"
                }
                require(part in 0..255) { "tunnel address is not IPv4: $tunnelIPv4Address" }
                (acc shl 8) or part.toLong()
            }
            val next = value + 1
            return (24 downTo 0 step 8).joinToString(".") { shift -> ((next shr shift) and 0xFF).toString() }
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
