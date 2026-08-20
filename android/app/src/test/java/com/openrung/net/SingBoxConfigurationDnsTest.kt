package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.URI

/**
 * Regression tests for the DoH emission and the probe-priority pins. TCP/53 through the proxy
 * receives no replies under WSS relays, and geosite-cn contains probe-class hostnames
 * (www.gstatic.com), so both properties below are load-bearing for startup truthfulness.
 */
class SingBoxConfigurationDnsTest {
    @Test
    fun `resolvers are emitted as DoH servers detoured through the proxy`() {
        val servers = SingBoxConfiguration(relay()).makeJsonObject().dnsServers()
        assertEquals(listOf("dns-0", "dns-1"), servers.map { it.tag() })
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), servers.map { it["server"]!!.jsonPrimitive.content })
        servers.forEach { server ->
            assertEquals("https", server["type"]!!.jsonPrimitive.content)
            assertEquals("proxy", server["detour"]!!.jsonPrimitive.content)
            // Defaults must stay in force: port 443 and path /dns-query.
            assertFalse(server.containsKey("server_port"))
            assertFalse(server.containsKey("path"))
            // IP-literal servers need no bootstrap resolver — the non-circularity guarantee.
            assertFalse(server.containsKey("domain_resolver"))
        }
        // TLS authenticates the provider hostname while the dial stays on the IP literal, so a
        // provider dropping IP SANs from its certificate cannot break resolution.
        assertEquals(
            listOf("cloudflare-dns.com", "dns.google"),
            servers.map { it["tls"]!!.jsonObject["server_name"]!!.jsonPrimitive.content },
        )
    }

    @Test
    fun `no dns server anywhere speaks plaintext dns`() {
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("ir", "cn")),
        ).makeJsonObject()
        config.dnsServers().forEach { server ->
            // Proxied resolvers need DoH because relays answer 443 on every transport while
            // TCP/53 gets no replies under WSS. The bypass-country resolvers need it for a
            // different reason: they are dialed DIRECTLY, so an unencrypted query would leave
            // the device on the user's real IP — in cleartext, and forgeable — while the tunnel
            // is up. Neither may ever regress to udp/tcp.
            assertEquals(
                "every dns server must be encrypted: ${server["tag"]!!.jsonPrimitive.content}",
                "https",
                server["type"]!!.jsonPrimitive.content,
            )
            assertNotNull(
                "an encrypted resolver must authenticate a provider hostname",
                server["tls"]?.jsonObject?.get("server_name"),
            )
        }
    }

    @Test
    fun `default domain resolver stays on the primary and final on the terminal fallback`() {
        val config = SingBoxConfiguration(relay()).makeJsonObject()
        // The global chain's trailing route rule is the real terminus; `final` names the same
        // fallback resolver for coherence.
        assertEquals("dns-1", config["dns"]!!.jsonObject["final"]!!.jsonPrimitive.content)
        assertEquals("3s", config["dns"]!!.jsonObject["timeout"]!!.jsonPrimitive.content)
        assertEquals(
            "dns-0",
            config["route"]!!.jsonObject["default_domain_resolver"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun `failover chain evaluates the primary then falls to the terminal fallback`() {
        // sing-box has no upstream failover of its own: `evaluate` is non-terminal on a
        // transport error/timeout/SERVFAIL/REFUSED, `respond` returns a usable answer (NOERROR,
        // or an authoritative NXDOMAIN), and the trailing route rule is the terminal fallback.
        val rules = SingBoxConfiguration(relay()).makeJsonObject()
            .dnsRules().takeLast(4)
        assertEquals("evaluate", rules[0]["action"]!!.jsonPrimitive.content)
        assertEquals("dns-0", rules[0]["server"]!!.jsonPrimitive.content)
        assertEquals("2s", rules[0]["timeout"]!!.jsonPrimitive.content)
        listOf("NOERROR" to rules[1], "NXDOMAIN" to rules[2]).forEach { (rcode, rule) ->
            assertEquals(true, rule["match_response"]!!.jsonPrimitive.content.toBoolean())
            assertEquals(rcode, rule["response_rcode"]!!.jsonPrimitive.content)
            assertEquals("respond", rule["action"]!!.jsonPrimitive.content)
        }
        assertEquals("dns-1", rules[3]["server"]!!.jsonPrimitive.content)
        assertEquals("3s", rules[3]["timeout"]!!.jsonPrimitive.content)
        assertFalse("the global chain must apply to every query", rules.any { it.containsKey("domain_suffix") })
    }

    @Test
    fun `probe dns chain is always first uncached and terminal for probe domains`() {
        val baseline = SingBoxConfiguration(relay()).makeJsonObject()
        val china = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("cn")),
        ).makeJsonObject()

        listOf(baseline, china).forEach { config ->
            val probeChain = config.dnsRules().take(4)
            // Every probe rule is scoped to the probe domains; the chain ends in a terminal
            // route rule, so a probe lookup can never leak past it into a country rule.
            probeChain.forEach { rule ->
                if (rule["match_response"]?.jsonPrimitive?.content?.toBoolean() != true) {
                    assertEquals(
                        ProbeTargets.RULE_DOMAIN_SUFFIXES,
                        rule["domain_suffix"]!!.jsonArray.map { it.jsonPrimitive.content },
                    )
                    assertEquals(true, rule["disable_cache"]!!.jsonPrimitive.content.toBoolean())
                    assertEquals(
                        true,
                        rule["disable_optimistic_cache"]!!.jsonPrimitive.content.toBoolean(),
                    )
                } else {
                    assertEquals(
                        ProbeTargets.RULE_DOMAIN_SUFFIXES,
                        rule["domain_suffix"]!!.jsonArray.map { it.jsonPrimitive.content },
                    )
                }
            }
            assertEquals("evaluate", probeChain[0]["action"]!!.jsonPrimitive.content)
            assertEquals("dns-0", probeChain[0]["server"]!!.jsonPrimitive.content)
            // Nonce probes legitimately draw NXDOMAIN; the primary answering one must respond.
            assertEquals("NXDOMAIN", probeChain[2]["response_rcode"]!!.jsonPrimitive.content)
            assertFalse(probeChain[3].containsKey("action"))
            assertEquals("dns-1", probeChain[3]["server"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `china bypass can never outrank the probe pins`() {
        // The confirmed regression: geosite-cn contains www.gstatic.com, so before these pins a
        // dead proxy still produced a passing probe over the direct path and the app published
        // CONNECTED. Probe DNS and probe routing must both win before any country rule.
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("cn")),
        ).makeJsonObject()

        val dnsRules = config.dnsRules()
        assertTrue(dnsRules[0].containsKey("domain_suffix"))
        assertEquals("dns-0", dnsRules[0]["server"]!!.jsonPrimitive.content)
        val countryDnsIndex = dnsRules.indexOfFirst { it.containsKey("rule_set") }
        assertEquals("country dns rule must follow the 4-rule probe chain", 4, countryDnsIndex)

        val routeRules = config["route"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }
        val probeRouteIndex = routeRules.indexOfFirst { rule ->
            rule["domain_suffix"]?.jsonArray?.map { it.jsonPrimitive.content } ==
                ProbeTargets.RULE_DOMAIN_SUFFIXES
        }
        val bypassRouteIndex = routeRules.indexOfFirst { rule ->
            rule["outbound"]?.jsonPrimitive?.content == "direct"
        }
        assertTrue("probe route pin must exist", probeRouteIndex >= 0)
        assertEquals("proxy", routeRules[probeRouteIndex]["outbound"]!!.jsonPrimitive.content)
        assertTrue(
            "probe route pin must precede every direct-bypass rule",
            bypassRouteIndex > probeRouteIndex,
        )
    }

    @Test
    fun `every through-tunnel probe endpoint is covered by the rule pins`() {
        InternetProbe.ENDPOINTS.forEach { endpoint ->
            val host = URI(endpoint).host
            assertTrue(
                "probe endpoint $host must be pinned through the proxy",
                ProbeTargets.RULE_DOMAIN_SUFFIXES.any { suffix ->
                    host == suffix || host.endsWith(".$suffix")
                },
            )
        }
        // The fresh-DNS nonce queries must land under a pinned suffix too.
        assertTrue(ProbeTargets.RULE_DOMAIN_SUFFIXES.contains(ProbeTargets.DNS_PROBE_QNAME_SUFFIX))
    }

    @Test
    fun `probe queries target the only address sing-box hijacks`() {
        // sing-box tags a packet as DNS — and hijacks it into the DNS module ahead of every
        // route rule — ONLY when its destination equals the TUN's derived DNS address (the next
        // address after the TUN's own IPv4 address, since we emit no dns_address). A probe sent
        // to a public resolver instead would match no rule and die on the TCP-only proxy
        // outbound, failing on every healthy tunnel.
        assertEquals("172.19.0.1/30", SingBoxConfiguration.DEFAULT_TUNNEL_IPV4_ADDRESS)
        assertEquals("172.19.0.2", SingBoxConfiguration.DEFAULT_TUNNEL_DNS_ADDRESS)
        assertEquals(
            SingBoxConfiguration.DEFAULT_TUNNEL_DNS_ADDRESS,
            SingBoxConfiguration.tunnelDnsAddress(
                SingBoxConfiguration(relay()).tunnelIPv4Address,
            ),
        )
        // Octet carry, so a future tunnel address change cannot silently derive a wrong hijack
        // address. The /23 keeps the successor inside the prefix.
        assertEquals("10.0.1.0", SingBoxConfiguration.tunnelDnsAddress("10.0.0.255/23"))
    }

    @Test
    fun `tunnel addresses whose dns successor escapes the prefix are rejected`() {
        // sing-tun refuses to derive a hijack address whose successor escapes the TUN prefix
        // (HasNextAddress), so returning one here would fail every probe on a healthy tunnel:
        // the last address of a prefix must be rejected, exactly like a non-IPv4 input.
        listOf(
            "10.0.0.255/30",
            "172.19.0.3/30",
            "172.19.0.1",
            "fdfe:dcba:9876::1/126",
            "bogus/30",
        ).forEach { invalid ->
            assertThrows(IllegalArgumentException::class.java) {
                SingBoxConfiguration.tunnelDnsAddress(invalid)
            }
        }
    }

    @Test
    fun `tun inbound never pins its own dns_address away from the derived one`() {
        // An explicit dns_address on the tun inbound would replace the derived hijack address
        // and silently invalidate the probe target above.
        val tunInbound = SingBoxConfiguration(relay()).makeJsonObject()["inbounds"]!!
            .jsonArray[0].jsonObject
        assertFalse(tunInbound.containsKey("dns_address"))
    }

    @Test
    fun `dns block is identical across direct and bridged shapes`() {
        val direct = SingBoxConfiguration(relay()).makeJsonObject()
        val bridged = SingBoxConfiguration(
            relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 54321,
        ).makeJsonObject()
        assertEquals(direct["dns"], bridged["dns"])
    }

    private fun JsonObject.dnsServers(): List<JsonObject> =
        this["dns"]!!.jsonObject["servers"]!!.jsonArray.map { it.jsonObject }
            .filter { it.tag().startsWith("dns-") && !it.tag().startsWith("dns-direct-") }

    private fun JsonObject.dnsRules(): List<JsonObject> =
        this["dns"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }

    private fun JsonObject.tag(): String = this["tag"]!!.jsonPrimitive.content

    private fun rules(
        bypassLan: Boolean = false,
        bypassCountries: List<String> = emptyList(),
    ): SplitTunnelRules = SplitTunnelRules(
        bypassLan = bypassLan,
        bypassCountries = bypassCountries,
        excludedPackages = emptyList(),
        ruleSetDirectory = "/data/user/0/rulesets",
    )

    private fun relay(): RelayDescriptor = RelayDescriptor(
        id = "relay-1",
        label = "test-relay",
        publicHost = "203.0.113.10",
        publicPort = 443,
        relayProtocol = "vless-reality-vision",
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "reality-key",
        shortId = "abcd1234",
        serverName = "www.example.com",
        flow = "xtls-rprx-vision",
        exitMode = "direct",
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        transport = "tunnel",
        punchCapable = true,
        punchEndpoint = "https://203.0.113.10:9444",
        registeredAt = "2026-01-01T00:00:00Z",
        lastHeartbeatAt = "2026-01-01T00:00:00Z",
        expiresAt = "2026-01-01T01:00:00Z",
    )
}
