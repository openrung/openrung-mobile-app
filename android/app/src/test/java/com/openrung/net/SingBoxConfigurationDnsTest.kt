package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SingBoxConfigurationDnsTest {
    @Test
    fun `proxied DNS uses non-circular DoH on 443`() {
        val dns = config()["dns"]!!.jsonObject
        val servers = dns["servers"]!!.jsonArray.map { it.jsonObject }

        assertEquals(2, servers.size)
        assertDohServer(
            server = servers[0],
            tag = "dns-proxy-primary",
            address = "1.1.1.1",
            tlsServerName = "cloudflare-dns.com",
        )
        assertDohServer(
            server = servers[1],
            tag = "dns-proxy-secondary",
            address = "8.8.8.8",
            tlsServerName = "dns.google",
        )
        assertEquals("dns-proxy-secondary", dns["final"]!!.jsonPrimitive.content)
    }

    @Test
    fun `conditional evaluate chain really fails over to secondary resolver`() {
        val rules = config()["dns"]!!.jsonObject["rules"]!!.jsonArray
            .map { it.jsonObject }
            .filterNot { it.containsKey("domain") }

        assertEquals(listOf("evaluate", "respond", "respond", "route"), rules.map(::action))
        assertEquals("dns-proxy-primary", rules[0]["server"]!!.jsonPrimitive.content)
        assertEquals("NOERROR", rules[1]["response_rcode"]!!.jsonPrimitive.content)
        assertEquals("NXDOMAIN", rules[2]["response_rcode"]!!.jsonPrimitive.content)
        assertEquals("dns-proxy-secondary", rules[3]["server"]!!.jsonPrimitive.content)

        assertEquals("dns-proxy-primary", selectedResolver(rules, "NOERROR"))
        assertEquals("dns-proxy-primary", selectedResolver(rules, "NXDOMAIN"))
        assertEquals("dns-proxy-secondary", selectedResolver(rules, "SERVFAIL"))
        assertEquals("dns-proxy-secondary", selectedResolver(rules, "REFUSED"))
        assertEquals("dns-proxy-secondary", selectedResolver(rules, null))
    }

    @Test
    fun `probe DNS and HTTPS rules outrank China bypass`() {
        val config = config(
            SplitTunnelRules(
                bypassLan = false,
                bypassCountries = listOf("cn"),
                excludedPackages = emptyList(),
                ruleSetDirectory = "/data/user/0/rulesets",
            ),
        )
        val dnsRules = config["dns"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }
        val directChinaDnsIndex = dnsRules.indexOfFirst {
            it["server"]?.jsonPrimitive?.content == "dns-direct-cn"
        }
        val probeRules = dnsRules.take(directChinaDnsIndex)

        assertTrue(directChinaDnsIndex > 0)
        assertEquals(listOf("evaluate", "respond", "route"), probeRules.map(::action))
        probeRules.forEach { rule ->
            assertEquals(
                SingBoxConfiguration.CONNECTIVITY_PROBE_HOST,
                rule["domain"]!!.jsonArray.single().jsonPrimitive.content,
            )
        }
        assertEquals("dns-proxy-primary", probeRules[0]["server"]!!.jsonPrimitive.content)
        assertEquals(true, probeRules[0]["disable_cache"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(true, probeRules[0]["disable_optimistic_cache"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(true, probeRules[1]["match_response"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(true, probeRules[1]["ip_accept_any"]!!.jsonPrimitive.content.toBoolean())
        assertEquals("dns-proxy-secondary", probeRules[2]["server"]!!.jsonPrimitive.content)
        assertEquals(true, probeRules[2]["disable_cache"]!!.jsonPrimitive.content.toBoolean())

        val routeRules = config["route"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }
        val forcedProxyIndex = routeRules.indexOfFirst { rule ->
            rule["domain"]?.jsonArray?.any {
                it.jsonPrimitive.content == SingBoxConfiguration.CONNECTIVITY_PROBE_HOST
            } == true
        }
        val directChinaRouteIndex = routeRules.indexOfFirst { rule ->
            rule["rule_set"]?.jsonArray?.any { it.jsonPrimitive.content == "geosite-cn" } == true
        }
        assertEquals("sniff", action(routeRules[forcedProxyIndex - 1]))
        assertEquals("proxy", routeRules[forcedProxyIndex]["outbound"]!!.jsonPrimitive.content)
        assertTrue(forcedProxyIndex < directChinaRouteIndex)
    }

    @Test
    fun `resolver bootstrap rejects hostnames and missing failover`() {
        assertThrows(IllegalArgumentException::class.java) {
            SingBoxConfiguration(
                relay = relay(),
                dnsOverHttpsResolvers = listOf(
                    DnsOverHttpsResolver("one", "dns.example", "dns.example"),
                    DnsOverHttpsResolver("two", "8.8.8.8", "dns.google"),
                ),
            ).makeJsonObject()
        }
        assertThrows(IllegalArgumentException::class.java) {
            SingBoxConfiguration(
                relay = relay(),
                dnsOverHttpsResolvers = listOf(
                    DnsOverHttpsResolver("only", "1.1.1.1", "cloudflare-dns.com"),
                ),
            ).makeJsonObject()
        }
    }

    private fun assertDohServer(
        server: JsonObject,
        tag: String,
        address: String,
        tlsServerName: String,
    ) {
        assertEquals(tag, server["tag"]!!.jsonPrimitive.content)
        assertEquals("https", server["type"]!!.jsonPrimitive.content)
        assertEquals(address, server["server"]!!.jsonPrimitive.content)
        assertEquals(443, server["server_port"]!!.jsonPrimitive.content.toInt())
        assertEquals("/dns-query", server["path"]!!.jsonPrimitive.content)
        assertEquals("proxy", server["detour"]!!.jsonPrimitive.content)
        assertFalse(server.containsKey("domain_resolver"))
        val tls = server["tls"]!!.jsonObject
        assertEquals(true, tls["enabled"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(tlsServerName, tls["server_name"]!!.jsonPrimitive.content)
    }

    /** Models pinned sing-box evaluate/respond behavior for a primary outcome. */
    private fun selectedResolver(rules: List<JsonObject>, primaryRcode: String?): String {
        var evaluatedBy: String? = null
        rules.forEach { rule ->
            when (action(rule)) {
                "evaluate" -> evaluatedBy = rule["server"]!!.jsonPrimitive.content
                "respond" -> if (
                    primaryRcode != null &&
                    rule["response_rcode"]!!.jsonPrimitive.content == primaryRcode
                ) {
                    return checkNotNull(evaluatedBy)
                }
                "route" -> return rule["server"]!!.jsonPrimitive.content
            }
        }
        error("resolver chain did not terminate")
    }

    private fun action(rule: JsonObject): String = rule["action"]!!.jsonPrimitive.content

    private fun config(splitTunnel: SplitTunnelRules? = null): JsonObject =
        SingBoxConfiguration(relay(), splitTunnel = splitTunnel).makeJsonObject()

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
