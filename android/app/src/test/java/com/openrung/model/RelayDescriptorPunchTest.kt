package com.openrung.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/**
 * Covers the NAT-punch relay fields: they deserialize from the broker's snake_case keys, default
 * cleanly when a relay/broker omits them, drive [RelayDescriptor.punchBaseUrl] the way the desktop
 * client resolves the hub URL, and — critically — never gate [RelayDescriptor.isUsable] (punch is an
 * accelerator, not a usability requirement).
 */
class RelayDescriptorPunchTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun relayJson(extra: String): String =
        """
        {
          "id": "relay_abc",
          "public_host": "203.0.113.7",
          "public_port": 443,
          "protocol": "vless-reality-vision",
          "client_id": "11111111-2222-3333-4444-555555555555",
          "reality_public_key": "pubkey",
          "short_id": "abcd",
          "server_name": "www.example.com",
          "flow": "xtls-rprx-vision",
          "exit_mode": "direct",
          "max_sessions": 4,
          "max_mbps": 100,
          "volunteer_version": "0.2.6",
          "registered_at": "2026-07-10T00:00:00Z",
          "last_heartbeat_at": "2026-07-10T00:00:00Z",
          "expires_at": "2999-01-01T00:00:00Z"$extra
        }
        """.trimIndent()

    @Test
    fun `deserializes punch fields when present`() {
        val relay = json.decodeFromString<RelayDescriptor>(
            relayJson(""","punch_capable": true, "punch_endpoint": "https://hub.example.org:9444""""),
        )
        assertTrue(relay.punchCapable)
        assertEquals("https://hub.example.org:9444", relay.punchEndpoint)
    }

    @Test
    fun `defaults punch fields when absent`() {
        val relay = json.decodeFromString<RelayDescriptor>(relayJson(""))
        assertFalse(relay.punchCapable)
        assertEquals("", relay.punchEndpoint)
    }

    @Test
    fun `punchBaseUrl uses advertised endpoint verbatim`() {
        val relay = json.decodeFromString<RelayDescriptor>(
            relayJson(""","punch_endpoint": "https://hub.example.org:9444""""),
        )
        assertEquals("https://hub.example.org:9444", relay.punchBaseUrl())
    }

    @Test
    fun `punchBaseUrl derives from public host when endpoint blank`() {
        val relay = json.decodeFromString<RelayDescriptor>(relayJson(""))
        assertEquals("http://203.0.113.7:9444", relay.punchBaseUrl())
    }

    @Test
    fun `punchBaseUrl brackets bare IPv6 public host`() {
        val relay = json.decodeFromString<RelayDescriptor>(
            relayJson(""","public_host": "2001:db8::1""""),
        )
        assertEquals("http://[2001:db8::1]:9444", relay.punchBaseUrl())
    }

    @Test
    fun `isUsable ignores punch capability`() {
        val now = Instant.parse("2026-07-10T00:00:00Z")
        val punchable = json.decodeFromString<RelayDescriptor>(relayJson(""","punch_capable": true"""))
        val plain = json.decodeFromString<RelayDescriptor>(relayJson(""))
        // Both are usable; punch_capable neither grants nor revokes usability.
        assertTrue(punchable.isUsable(now))
        assertTrue(plain.isUsable(now))
    }
}
