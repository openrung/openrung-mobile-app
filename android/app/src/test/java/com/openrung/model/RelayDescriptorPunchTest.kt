package com.openrung.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelayDescriptorPunchTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `decodes signed directory punch metadata`() {
        val relay = json.decodeFromString<RelayDescriptor>(descriptorJson(
            """"transport":"tunnel","punch_capable":true,"punch_endpoint":"https://43.201.124.63:9444",""",
        ))
        assertEquals("tunnel", relay.transport)
        assertTrue(relay.punchCapable)
        assertEquals("https://43.201.124.63:9444", relay.punchEndpoint)
    }

    @Test
    fun `older descriptors default to hub-only behavior`() {
        val relay = json.decodeFromString<RelayDescriptor>(descriptorJson(""))
        assertEquals("", relay.transport)
        assertFalse(relay.punchCapable)
        assertEquals("", relay.punchEndpoint)
    }

    private fun descriptorJson(extra: String): String = """
        {
          "id":"relay-1",
          "public_host":"203.0.113.10",
          "public_port":443,
          "protocol":"vless-reality-vision",
          "client_id":"e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
          "reality_public_key":"key",
          "short_id":"abcd",
          "server_name":"www.example.com",
          "flow":"xtls-rprx-vision",
          "exit_mode":"direct",
          "max_sessions":8,
          "max_mbps":100,
          "volunteer_version":"1.0.0",
          $extra
          "registered_at":"2026-01-01T00:00:00Z",
          "last_heartbeat_at":"2026-01-01T00:00:00Z",
          "expires_at":"2026-01-01T01:00:00Z"
        }
    """.trimIndent()
}
