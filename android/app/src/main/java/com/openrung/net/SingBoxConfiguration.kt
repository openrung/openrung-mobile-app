package com.openrung.net

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

data class SingBoxConfiguration(
    val relay: RelayDescriptor,
    /** Loopback TCP adapter exposed by a native transport. Empty means use the relay endpoint. */
    val bridgeHost: String = "",
    val bridgePort: Int = 0,
    val tunnelIPv4Address: String = "172.19.0.1/30",
    val tunnelIPv6Address: String = "fdfe:dcba:9876::1/126",
    val dnsServers: List<String> = listOf("1.1.1.1", "8.8.8.8"),
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
                put("level", "info")
                put("timestamp", true)
            })
            put("dns", buildJsonObject {
                put("servers", buildJsonArray {
                    dnsServers.forEachIndexed { index, server ->
                        add(buildJsonObject {
                            put("tag", "dns-$index")
                            put("type", "tcp")
                            put("server", server)
                            put("detour", "proxy")
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
                if (bypassCountries.isNotEmpty()) {
                    put("rules", buildJsonArray {
                        bypassCountries.forEach { country ->
                            add(buildJsonObject {
                                put("rule_set", JsonArray(listOf(JsonPrimitive("geosite-$country"))))
                                put("server", "dns-direct-$country")
                            })
                        }
                    })
                }
                put("final", "dns-0")
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
