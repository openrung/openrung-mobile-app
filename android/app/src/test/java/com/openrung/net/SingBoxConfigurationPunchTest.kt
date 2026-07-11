package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers the punch-mode sing-box config deltas versus the relay (direct) path: the VLESS outbound is
 * redirected to the loopback bridge while the Reality identity is preserved, and the volunteer's
 * reflexive IP joins the relay hub in route_exclude_address. Without punch params the config must be
 * byte-identical to today.
 */
class SingBoxConfigurationPunchTest {

    private fun relay(publicHost: String = "203.0.113.7"): RelayDescriptor =
        RelayDescriptor(
            id = "relay_abc",
            publicHost = publicHost,
            publicPort = 443,
            relayProtocol = "vless-reality-vision",
            clientId = "11111111-2222-3333-4444-555555555555",
            realityPublicKey = "pubkey",
            shortId = "abcd",
            serverName = "www.example.com",
            flow = "xtls-rprx-vision",
            exitMode = "direct",
            maxSessions = 4,
            maxMbps = 100,
            volunteerVersion = "0.2.6",
            registeredAt = "2026-07-10T00:00:00Z",
            lastHeartbeatAt = "2026-07-10T00:00:00Z",
            expiresAt = "2999-01-01T00:00:00Z",
        )

    private fun proxyOutbound(config: JsonObject): JsonObject =
        config["outbounds"]!!.jsonArray
            .map { it.jsonObject }
            .first { it["tag"]?.jsonPrimitive?.content == "proxy" }

    private fun routeExclude(config: JsonObject): List<String> {
        val tun = config["inbounds"]!!.jsonArray[0].jsonObject
        val excl = tun["route_exclude_address"] as? JsonArray ?: return emptyList()
        return excl.map { it.jsonPrimitive.content }
    }

    @Test
    fun `direct path dials the relay public endpoint and excludes only the hub`() {
        val config = SingBoxConfiguration(relay = relay()).makeJsonObject()
        val proxy = proxyOutbound(config)
        assertEquals(JsonPrimitive("203.0.113.7"), proxy["server"])
        assertEquals(JsonPrimitive(443), proxy["server_port"])
        assertEquals(listOf("203.0.113.7/32"), routeExclude(config))
    }

    @Test
    fun `punch path dials the loopback bridge`() {
        val config = SingBoxConfiguration(
            relay = relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 51820,
            punchPeerExcludeAddress = "198.51.100.9",
        ).makeJsonObject()
        val proxy = proxyOutbound(config)
        assertEquals(JsonPrimitive("127.0.0.1"), proxy["server"])
        assertEquals(JsonPrimitive(51820), proxy["server_port"])
    }

    @Test
    fun `punch path preserves the Reality identity`() {
        val config = SingBoxConfiguration(
            relay = relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 51820,
            punchPeerExcludeAddress = "198.51.100.9",
        ).makeJsonObject()
        val tls = proxyOutbound(config)["tls"]!!.jsonObject
        // Identity fields still target the real volunteer, so Reality validates end-to-end.
        assertEquals(JsonPrimitive("www.example.com"), tls["server_name"])
        assertEquals(JsonPrimitive("pubkey"), tls["reality"]!!.jsonObject["public_key"])
        assertEquals(JsonPrimitive("abcd"), tls["reality"]!!.jsonObject["short_id"])
        assertEquals(
            JsonPrimitive("11111111-2222-3333-4444-555555555555"),
            proxyOutbound(config)["uuid"],
        )
    }

    @Test
    fun `punch path excludes both the hub and the volunteer reflexive IP`() {
        val config = SingBoxConfiguration(
            relay = relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 51820,
            punchPeerExcludeAddress = "198.51.100.9",
        ).makeJsonObject()
        val excludes = routeExclude(config)
        assertTrue("hub excluded", excludes.contains("203.0.113.7/32"))
        assertTrue("peer excluded", excludes.contains("198.51.100.9/32"))
        assertEquals(2, excludes.size)
    }

    @Test
    fun `punch peer exclude only applies when the peer IP is a literal`() {
        // A blank peer IP must not add a stray exclusion (defensive: maybePunch always sets one on
        // success, but the config layer must not choke on a hostname or null).
        val config = SingBoxConfiguration(
            relay = relay(),
            bridgeHost = "127.0.0.1",
            bridgePort = 51820,
            punchPeerExcludeAddress = null,
        ).makeJsonObject()
        assertEquals(listOf("203.0.113.7/32"), routeExclude(config))
    }
}
