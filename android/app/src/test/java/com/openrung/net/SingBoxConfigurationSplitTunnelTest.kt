package com.openrung.net

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Split-tunnel emission expectations, asserted against the frozen bound outputs under
 * testdata/singbox-binding (see [SingBoxBindingFixtures]). The scenario inputs these goldens are
 * built from are pinned by [SingBoxConfigurationBindingInputTest].
 */
class SingBoxConfigurationSplitTunnelTest {
    @Test
    fun `all-empty split rules emit the exact no-split configuration`() {
        assertEquals(
            SingBoxBindingFixtures.goldenText("android-tun"),
            SingBoxBindingFixtures.goldenText("android-split-empty"),
        )
    }

    @Test
    fun `lan-only bypass adds exactly one route rule and nothing else`() {
        val baseline = SingBoxBindingFixtures.golden("android-tun")
        val config = SingBoxBindingFixtures.golden("android-split-lan")

        val routeRules = config.routeRules()
        assertEquals(baseline.routeRules().size + 1, routeRules.size)
        val lanRule = routeRules[1].jsonObject
        assertEquals(true, lanRule["ip_is_private"]!!.jsonPrimitive.content.toBoolean())
        assertEquals("direct", lanRule["outbound"]!!.jsonPrimitive.content)
        assertFalse(routeRules.any { "sniff" == it.jsonObject["action"]?.jsonPrimitive?.content })

        // Only the always-on probe/global failover chains; no country rules without countries.
        assertEquals(baseline["dns"], config["dns"])
        assertFalse(config["route"]!!.jsonObject.containsKey("rule_set"))
        assertFalse(config.tunInbound().containsKey("exclude_package"))
    }

    @Test
    fun `single country bypass wires dns and route rule sets`() {
        val config = SingBoxBindingFixtures.golden("android-split-ir")

        val routeRules = config.routeRules()
        assertEquals("hijack-dns", routeRules[0].jsonObject["action"]!!.jsonPrimitive.content)
        assertEquals("sniff", routeRules[1].jsonObject["action"]!!.jsonPrimitive.content)
        // The probe pin must sit between sniff and every bypass rule.
        val probeRule = routeRules[2].jsonObject
        assertEquals(
            ProbeTargets.RULE_DOMAIN_SUFFIXES,
            probeRule["domain_suffix"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals("proxy", probeRule["outbound"]!!.jsonPrimitive.content)
        val countryRule = routeRules[3].jsonObject
        assertEquals(
            listOf("geosite-ir", "geoip-ir"),
            countryRule["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals("direct", countryRule["outbound"]!!.jsonPrimitive.content)
        assertEquals(4, routeRules.size)

        val dns = config["dns"]!!.jsonObject
        // Iran has no encrypted public resolver we can currently stand behind, so it contributes
        // no dns server and no dns rules at all — its ROUTE bypass above is untouched, and its
        // lookups just reach the proxied global chain. A dead primary would be strictly worse:
        // every bypassed lookup would burn the full evaluate timeout on a doomed TLS handshake.
        assertEquals(SingBoxBindingFixtures.golden("android-tun")["dns"], config["dns"])
        assertTrue(
            dns["servers"]!!.jsonArray.none {
                it.jsonObject["tag"]!!.jsonPrimitive.content.startsWith("dns-direct-")
            },
        )

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
        val config = SingBoxBindingFixtures.golden("android-split-ir-cn-lan")

        val routeRules = config.routeRules().map { it.jsonObject }
        assertEquals(6, routeRules.size)
        assertEquals("hijack-dns", routeRules[0]["action"]!!.jsonPrimitive.content)
        assertEquals("sniff", routeRules[1]["action"]!!.jsonPrimitive.content)
        assertEquals("proxy", routeRules[2]["outbound"]!!.jsonPrimitive.content)
        assertEquals(true, routeRules[3]["ip_is_private"]!!.jsonPrimitive.content.toBoolean())
        assertEquals(
            listOf("geosite-ir", "geoip-ir"),
            routeRules[4]["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertEquals(
            listOf("geosite-cn", "geoip-cn"),
            routeRules[5]["rule_set"]!!.jsonArray.map { it.jsonPrimitive.content },
        )

        val dns = config["dns"]!!.jsonObject
        // Only China contributes a resolver today (see connectcore's split-tunnel resolver
        // table), but the ROUTE rules above still cover both countries.
        val directServers = dns["servers"]!!.jsonArray.map { it.jsonObject }
            .filter { it["tag"]!!.jsonPrimitive.content.startsWith("dns-direct-") }
        assertEquals(
            listOf("dns-direct-cn"),
            directServers.map { it["tag"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("223.5.5.5"),
            directServers.map { it["server"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("dns.alidns.com"),
            directServers.map { it["tls"]!!.jsonObject["server_name"]!!.jsonPrimitive.content },
        )
        assertTrue(directServers.none { it.containsKey("detour") })
        assertEquals(
            listOf("dns-direct-cn"),
            dns["rules"]!!.jsonArray.map { it.jsonObject }
                .filter { it.containsKey("rule_set") && it.containsKey("server") }
                .map { it["server"]!!.jsonPrimitive.content },
        )
        assertEquals(
            listOf("geosite-ir", "geoip-ir", "geosite-cn", "geoip-cn"),
            config["route"]!!.jsonObject["rule_set"]!!.jsonArray
                .map { it.jsonObject["tag"]!!.jsonPrimitive.content },
        )
    }

    @Test
    fun `excluded packages land on the tun inbound and never as include_package`() {
        val tunInbound = SingBoxBindingFixtures.golden("android-split-packages").tunInbound()
        assertEquals(
            listOf("com.tencent.mm", "org.telegram.messenger"),
            tunInbound["exclude_package"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        assertFalse(tunInbound.containsKey("include_package"))
    }

    @Test
    fun `bridge mode keeps split rules and still omits the endpoint route exclusion`() {
        val direct = SingBoxBindingFixtures.golden("android-split-ir-cn-lan")
        val bridged = SingBoxBindingFixtures.golden("android-split-ir-cn-lan-bridge")

        assertEquals(direct["dns"], bridged["dns"])
        assertEquals(direct["route"], bridged["route"])
        // Leak-precedent regression guard: the punch/WSS loopback adapter must never regain a
        // peer /32 exclusion because split tunneling is on.
        assertFalse(bridged.tunInbound().containsKey("route_exclude_address"))
        assertTrue(direct.tunInbound().containsKey("route_exclude_address"))
    }

    private fun JsonObject.routeRules(): JsonArray =
        this["route"]!!.jsonObject["rules"]!!.jsonArray

    private fun JsonObject.tunInbound(): JsonObject =
        this["inbounds"]!!.jsonArray[0].jsonObject
}
