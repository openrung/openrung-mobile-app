package com.openrung.net

import com.openrung.BuildConfig
import com.openrung.model.RelayDescriptor
import io.nekohasekai.libbox.Libbox
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject

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
    }
}

/**
 * Platform input assembly for the shared sing-box config builder: gathers the Android-side inputs
 * (relay identity, TUN addresses, an optional punch/WSS loopback bridge, validated split-tunnel
 * rules) and hands them to the libbox binding's `OpenRungBuildSingBoxConfig`, whose emission comes
 * from the one Go builder every OpenRung client runs (`connectcore/client` in the sibling
 * `openrung` repo — the generator this file used to hand-copy). This file no longer emits any
 * config JSON; the DNS failover chains, probe pins, split-tunnel rules, route exclusions, and
 * their ordering all live in the shared builder, and the frozen bound outputs under
 * `testdata/singbox-binding/` are what this platform's structural tests assert against.
 *
 * The assembly ([bindingInputJson]) is pure JVM so the test suite can pin it without the native
 * library; the input→config half runs in `android/punchbridge`'s Go tests against the same
 * checked-in inputs.
 */
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
    /**
     * The emitted config JSON from the shared builder. Throws [IllegalArgumentException] when the
     * binding rejects the input (an invalid relay, a partial bridge, an unsupported split-tunnel
     * country, …) — the same failures the deleted generator used to reject locally.
     */
    fun encodedJsonString(): String {
        val result = Libbox.openRungBuildSingBoxConfig(bindingInputJson())
        require(result.succeeded()) {
            result.errorText().ifBlank { "sing-box config build failed" }
        }
        return result.configJSON()
    }

    /**
     * The binding input for this configuration: one JSON object of the platform-assembled fields.
     * The relay object carries the broker's canonical wire names, the probe suffixes come from
     * [ProbeTargets] so the builder's probe pins can never diverge from the endpoints this
     * platform actually probes, and [debug] selects the log level ("info" logs every flow and DNS
     * query inside the Go engine; release builds keep only warnings to stay off the
     * per-connection hot path). Values are forwarded faithfully — a partial bridge is the
     * binding's to reject, not this assembly's to repair.
     */
    internal fun bindingInputJson(debug: Boolean = BuildConfig.DEBUG): String = buildJsonObject {
        putJsonObject("relay") {
            put("public_host", relay.publicHost)
            put("public_port", relay.publicPort)
            put("protocol", relay.relayProtocol)
            put("client_id", relay.clientId)
            put("reality_public_key", relay.realityPublicKey)
            put("short_id", relay.shortId)
            put("server_name", relay.serverName)
            put("flow", relay.flow)
            put("exit_mode", relay.exitMode)
        }
        put("tunnel_ipv4_address", tunnelIPv4Address)
        put("tunnel_ipv6_address", tunnelIPv6Address)
        put("mtu", mtu)
        if (bridgeHost.isNotBlank()) put("bridge_host", bridgeHost)
        if (bridgePort != 0) put("bridge_port", bridgePort)
        put("log_level", if (debug) "info" else "warn")
        put("route_find_process", true)
        putJsonArray("probe_domain_suffixes") {
            ProbeTargets.RULE_DOMAIN_SUFFIXES.forEach { add(it) }
        }
        splitTunnel?.let { rules ->
            putJsonObject("split_tunnel") {
                put("bypass_lan", rules.bypassLan)
                putJsonArray("bypass_countries") { rules.bypassCountries.forEach { add(it) } }
                putJsonArray("excluded_packages") { rules.excludedPackages.forEach { add(it) } }
                put("rule_set_directory", rules.ruleSetDirectory)
            }
        }
    }.toString()

    companion object {
        /**
         * The proxied DoH resolvers the shared builder emits by default (its defaults are the
         * same IP literals). Kept here because the probe budgets below are derived from the
         * chain's length and timeouts; the bound goldens pin the emitted list, so a builder-side
         * change cannot drift past this constant unnoticed.
         */
        val DEFAULT_DOH_RESOLVERS = listOf("1.1.1.1", "8.8.8.8")

        // Per-evaluate budget before the next resolver runs, and the terminal/global budget —
        // the shared builder's dnsPrimaryTimeout/dnsFallbackTimeout, in milliseconds.
        const val DNS_PRIMARY_TIMEOUT_MS = 2_000L
        const val DNS_FALLBACK_TIMEOUT_MS = 3_000L

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
         * carries no explicit `dns_address` (the shared builder emits none), sing-tun derives the
         * hijack address as the next address after the TUN's own IPv4 address, and the tun
         * inbound tags a packet `Protocol=DNS` only when its destination equals that address —
         * after which the router hijacks it into the DNS module ahead of any route rule. A
         * datagram addressed to a public resolver (1.1.1.1) is NOT tagged, matches no rule, and
         * dies on the TCP-only proxy outbound, so the fresh-DNS probe must target this address.
         */
        val DEFAULT_TUNNEL_DNS_ADDRESS = tunnelDnsAddress(DEFAULT_TUNNEL_IPV4_ADDRESS)

        /**
         * Next IPv4 address after [tunnelIPv4Address], mirroring sing-tun's derivation.
         *
         * sing-tun only performs that derivation when the successor stays inside the TUN
         * prefix (HasNextAddress: prefix.Contains(addr.Next())); otherwise it hijacks no IPv4
         * address at all. A tunnel address whose successor escapes the prefix is therefore
         * rejected here — returning it would hand probes an address sing-box never hijacks
         * and fail them on a healthy tunnel.
         */
        fun tunnelDnsAddress(tunnelIPv4Address: String): String {
            val prefixLength = tunnelIPv4Address
                .substringAfter("/", missingDelimiterValue = "")
                .toIntOrNull()
            require(prefixLength != null && prefixLength in 0..32) {
                "tunnel address is not an IPv4 prefix: $tunnelIPv4Address"
            }
            val octets = tunnelIPv4Address.substringBefore("/").split(".")
            require(octets.size == 4) { "tunnel address is not an IPv4 prefix: $tunnelIPv4Address" }
            val value = octets.fold(0L) { acc, octet ->
                val part = requireNotNull(octet.toIntOrNull()) {
                    "tunnel address is not an IPv4 prefix: $tunnelIPv4Address"
                }
                require(part in 0..255) { "tunnel address is not an IPv4 prefix: $tunnelIPv4Address" }
                (acc shl 8) or part.toLong()
            }
            val next = value + 1
            val networkShift = 32 - prefixLength
            require(value shr networkShift == next shr networkShift) {
                "tunnel address $tunnelIPv4Address has no successor inside its prefix for sing-tun to hijack"
            }
            return (24 downTo 0 step 8).joinToString(".") { shift -> ((next shr shift) and 0xFF).toString() }
        }
    }
}
