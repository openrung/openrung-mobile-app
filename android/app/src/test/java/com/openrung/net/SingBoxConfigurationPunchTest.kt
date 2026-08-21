package com.openrung.net

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Punched/bridged emission expectations, asserted against the frozen bound outputs under
 * testdata/singbox-binding (see [SingBoxBindingFixtures]). The partial-bridge rejection the old
 * generator enforced locally lives in the binding now, pinned by android/punchbridge's Go
 * validation tests; [SingBoxConfigurationBindingInputTest] pins that a partial bridge is
 * forwarded faithfully for it to reject.
 */
class SingBoxConfigurationPunchTest {
    @Test
    fun `punch bridge changes only the transport endpoint`() {
        val relay = SingBoxBindingFixtures.relay()
        val config = SingBoxBindingFixtures.golden("android-bridge")

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
        val config = SingBoxBindingFixtures.golden("android-tun")
        val outbound = config["outbounds"]!!.jsonArray[0].jsonObject
        assertEquals("203.0.113.10", outbound["server"]!!.jsonPrimitive.content)
        assertEquals(443, outbound["server_port"]!!.jsonPrimitive.content.toInt())

        val tunInbound = config["inbounds"]!!.jsonArray[0].jsonObject
        val excluded = tunInbound["route_exclude_address"] as JsonArray
        assertTrue(excluded.any { it.jsonPrimitive.content == "203.0.113.10/32" })
    }
}
