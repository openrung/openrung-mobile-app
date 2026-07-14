package com.openrung.net

import com.openrung.model.RelayDescriptor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SingBoxConfigurationPunchTest {
    @Test
    fun `punch bridge changes only the transport endpoint`() {
        val relay = relay()
        val config = SingBoxConfiguration(
            relay = relay,
            bridgeHost = "127.0.0.1",
            bridgePort = 54321,
        ).makeJsonObject()

        val outbound = config["outbounds"]!!.jsonArray[0].jsonObject
        assertEquals("127.0.0.1", outbound["server"]!!.jsonPrimitive.content)
        assertEquals(54321, outbound["server_port"]!!.jsonPrimitive.content.toInt())
        assertEquals(relay.clientId, outbound["uuid"]!!.jsonPrimitive.content)
        assertEquals(relay.flow, outbound["flow"]!!.jsonPrimitive.content)

        val tls = outbound["tls"]!!.jsonObject
        assertEquals(relay.serverName, tls["server_name"]!!.jsonPrimitive.content)
        val reality = tls["reality"]!!.jsonObject
        assertEquals(relay.realityPublicKey, reality["public_key"]!!.jsonPrimitive.content)
        assertEquals(relay.shortId, reality["short_id"]!!.jsonPrimitive.content)

        // VpnService.protect(fd) exempts only the Go QUIC socket. A peer /32
        // route exclusion would leak unrelated apps' traffic to that IP.
        val tunInbound = config["inbounds"]!!.jsonArray[0].jsonObject
        assertFalse(tunInbound.containsKey("route_exclude_address"))
    }

    @Test
    fun `ordinary relay path keeps its endpoint route exclusion`() {
        val config = SingBoxConfiguration(relay()).makeJsonObject()
        val outbound = config["outbounds"]!!.jsonArray[0].jsonObject
        assertEquals("203.0.113.10", outbound["server"]!!.jsonPrimitive.content)
        assertEquals(443, outbound["server_port"]!!.jsonPrimitive.content.toInt())

        val tunInbound = config["inbounds"]!!.jsonArray[0].jsonObject
        val excluded = tunInbound["route_exclude_address"] as JsonArray
        assertTrue(excluded.any { it.jsonPrimitive.content == "203.0.113.10/32" })
    }

    @Test
    fun `rejects a partial punch bridge`() {
        assertThrows(IllegalArgumentException::class.java) {
            SingBoxConfiguration(relay(), bridgeHost = "127.0.0.1").encodedJsonString()
        }
        assertThrows(IllegalArgumentException::class.java) {
            SingBoxConfiguration(relay(), bridgePort = 1234).encodedJsonString()
        }
    }

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
