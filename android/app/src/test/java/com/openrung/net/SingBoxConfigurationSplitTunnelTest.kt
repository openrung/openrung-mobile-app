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

class SingBoxConfigurationSplitTunnelTest {
    @Test
    fun `null split tunnel emits the exact no-split configuration`() {
        val baseline = SingBoxConfiguration(relay()).makeJsonObject()
        assertEquals(baseline, SingBoxConfiguration(relay(), splitTunnel = null).makeJsonObject())
    }

    @Test
    fun `all-empty split rules emit the exact no-split configuration`() {
        val baseline = SingBoxConfiguration(relay()).makeJsonObject()
        val noop = SingBoxConfiguration(relay(), splitTunnel = rules()).makeJsonObject()
        assertEquals(baseline, noop)
    }

    @Test
    fun `lan-only bypass adds exactly one route rule and nothing else`() {
        val baseline = SingBoxConfiguration(relay()).makeJsonObject()
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassLan = true),
        ).makeJsonObject()

        val routeRules = config.routeRules()
        assertEquals(baseline.routeRules().size + 1, routeRules.size)
        val lanRule = routeRules[1].jsonObject
        assertEquals(true, lanRule["ip_is_private"]!!.jsonPrimitive.content.toBoolean())
        assertEquals("direct", lanRule["outbound"]!!.jsonPrimitive.content)
        assertFalse(routeRules.any { "sniff" == it.jsonObject["action"]?.jsonPrimitive?.content })

        assertFalse(config["dns"]!!.jsonObject.containsKey("rules"))
        assertFalse(config["route"]!!.jsonObject.containsKey("rule_set"))
        assertFalse(config.tunInbound().containsKey("exclude_package"))
    }

    @Test
    fun `single country bypass wires dns and route rule sets`() {
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassCountries = listOf("ir")),
        ).makeJsonObject()

        val routeRules = config.routeRules()
        assertEquals("hijack-dns", routeRules[0].jsonObject["action"]!!.jsonPrimitive.content)
        assertEquals("sniff", routeRules[1].jsonObject["action"]!!.jsonPrimitive.content)
        val countryRule = routeRules[2].jsonObject
        assertEquals(
            listOf("geosite-ir", "geoip-ir"),
            countryRule["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals("direct", countryRule["outbound"]!!.jsonPrimitive.content)
        assertEquals(3, routeRules.size)

        val dns = config["dns"]!!.jsonObject
        val directServer = dns["servers"]!!.jsonArray.last().jsonObject
        assertEquals("dns-direct-ir", directServer["tag"]!!.jsonPrimitive.content)
        assertEquals("udp", directServer["type"]!!.jsonPrimitive.content)
        assertEquals("178.22.122.100", directServer["server"]!!.jsonPrimitive.content)
        assertEquals("direct", directServer["detour"]!!.jsonPrimitive.content)

        val dnsRules = dns["rules"]!!.jsonArray
        assertEquals(1, dnsRules.size)
        assertEquals(
            listOf("geosite-ir"),
            dnsRules[0].jsonObject["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals("dns-direct-ir", dnsRules[0].jsonObject["server"]!!.jsonPrimitive.content)

        val ruleSets = config["route"]!!.jsonObject["rule_set"]!!.jsonArray.map { it.jsonObject }
        assertEquals(listOf("geosite-ir", "geoip-ir"), ruleSets.map { it["tag"]!!.jsonPrimitive.content })
        ruleSets.forEach { ruleSet ->
            assertEquals("local", ruleSet["type"]!!.jsonPrimitive.content)
            assertEquals("binary", ruleSet["format"]!!.jsonPrimitive.content)
            val tag = ruleSet["tag"]!!.jsonPrimitive.content
            assertEquals("/data/user/0/rulesets/$tag.srs", ruleSet["path"]!!.jsonPrimitive.content)
        }
    }

    @Test
    fun `both countries plus lan keep the full canonical rule order`() {
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(bypassLan = true, bypassCountries = listOf("ir", "cn")),
        ).makeJsonObject()

        val routeRules = config.routeRules().map { it.jsonObject }
        assertEquals(5, routeRules.size)
        assertEquals("hijack-dns", routeRules[0]["action"]!!.jsonPrimitive.content)
        assertEquals("sniff", routeRules[1]["action"]!!.jsonPrimitive.content)
        assertEquals(true, routeRules[2]["ip_is_private"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(
            listOf("geosite-ir", "geoip-ir"),
            routeRules[3]["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(
            listOf("geosite-cn", "geoip-cn"),
            routeRules[4]["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )

        val dns = config["dns"]!!.jsonObject
        val directServers = dns["servers"]!!.jsonArray.takeLast(2).map { it.jsonObject }
        assertEquals(
            listOf("dns-direct-ir", "dns-direct-cn"),
            directServers.map { it["tag"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("178.22.122.100", "223.5.5.5"),
            directServers.map { it["server"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("dns-direct-ir", "dns-direct-cn"),
            dns["rules"]!!.jsonArray.map { it.jsonObject["server"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("geosite-ir", "geoip-ir", "geosite-cn", "geoip-cn"),
            config["route"]!!.jsonObject["rule_set"]!!.jsonArray
                .map { it.jsonObject["tag"]!!.jsonPrimitive.content },
        )
    }

    @Test
    fun `excluded packages land on the tun inbound and never as include_package`() {
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = rules(excludedPackages = listOf("com.tencent.mm", "org.telegram.messenger")),
        ).makeJsonObject()

        val tunInbound = config.tunInbound()
        assertEquals(
            listOf("com.tencent.mm", "org.telegram.messenger"),
            tunInbound["exclude_package"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertFalse(tunInbound.containsKey("include_package"))
    }

    @Test
    fun `bridge mode keeps split rules and still omits the endpoint route exclusion`() {
        val splitTunnel = rules(bypassLan = true, bypassCountries = listOf("ir", "cn"))
        val direct = SingBoxConfiguration(relay(), splitTunnel = splitTunnel).makeJsonObject()
        val bridged = SingBoxConfiguration(
            relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 54321,
            splitTunnel = splitTunnel,
        ).makeJsonObject()

        assertEquals(direct["dns"], bridged["dns"])
        assertEquals(direct["route"], bridged["route"])
        // Leak-precedent regression guard: the punch/WSS loopback adapter must never regain a
        // peer /32 exclusion because split tunneling is on.
        assertFalse(bridged.tunInbound().containsKey("route_exclude_address"))
        assertTrue(direct.tunInbound().containsKey("route_exclude_address"))
    }

    private fun rules(
        bypassLan: Boolean = false,
        bypassCountries: List<String> = emptyList(),
        excludedPackages: List<String> = emptyList(),
        ruleSetDirectory: String = "/data/user/0/rulesets",
    ): SplitTunnelRules = SplitTunnelRules(
        bypassLan = bypassLan,
        bypassCountries = bypassCountries,
        excludedPackages = excludedPackages,
        ruleSetDirectory = ruleSetDirectory,
    )

    private fun JsonObject.routeRules(): JsonArray =
        this["route"]!!.jsonObject["rules"]!!.jsonArray

    private fun JsonObject.tunInbound(): JsonObject =
        this["inbounds"]!!.jsonArray[0].jsonObject

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
