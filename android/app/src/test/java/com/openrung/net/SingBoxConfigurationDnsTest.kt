package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    }

    @Test
    fun `no dns server speaks tcp or udp port 53 through the proxy`() {
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("ir", "cn")),
        ).makeJsonObject()
        config.dnsServers().forEach { server ->
            val type = server["type"]!!.jsonPrimitive.content
            if (server["detour"]?.jsonPrimitive?.content == "proxy") {
                assertEquals("proxied resolvers must use DoH over 443", "https", type)
            }
        }
    }

    @Test
    fun `final and default domain resolver stay pinned to the primary`() {
        val config = SingBoxConfiguration(relay()).makeJsonObject()
        assertEquals("dns-0", config["dns"]!!.jsonObject["final"]!!.jsonPrimitive.content)
        assertEquals(
            "dns-0",
            config["route"]!!.jsonObject["default_domain_resolver"]!!.jsonPrimitive.content,
        )
    }

    @Test
    fun `probe dns pin is always first proxied and uncached`() {
        val baseline = SingBoxConfiguration(relay()).makeJsonObject()
        val china = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("cn")),
        ).makeJsonObject()

        listOf(baseline, china).forEach { config ->
            val probeRule = config["dns"]!!.jsonObject["rules"]!!.jsonArray[0].jsonObject
            assertEquals(
                ProbeTargets.RULE_DOMAIN_SUFFIXES,
                probeRule["domain_suffix"]!!.jsonArray.map { it.jsonPrimitive.content },
            )
            assertEquals("dns-0", probeRule["server"]!!.jsonPrimitive.content)
            assertEquals(true, probeRule["disable_cache"]!!.jsonPrimitive.content.toBoolean())
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

        val dnsRules = config["dns"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }
        assertTrue(dnsRules[0].containsKey("domain_suffix"))
        assertEquals("dns-0", dnsRules[0]["server"]!!.jsonPrimitive.content)
        val countryDnsIndex = dnsRules.indexOfFirst { it.containsKey("rule_set") }
        assertTrue("country dns rule must exist", countryDnsIndex > 0)

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
    fun `rotated resolver order swaps the final resolver`() {
        val rotation = DnsResolverRotation()
        assertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))

        val rotated = SingBoxConfiguration(
            relay(),
            dnsServers = rotation.currentServers(),
        ).makeJsonObject().dnsServers()
        assertEquals("dns-0", rotated[0].tag())
        assertEquals("8.8.8.8", rotated[0]["server"]!!.jsonPrimitive.content)
        assertEquals("1.1.1.1", rotated[1]["server"]!!.jsonPrimitive.content)
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
        // address.
        assertEquals("10.0.1.0", SingBoxConfiguration.tunnelDnsAddress("10.0.0.255/30"))
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
