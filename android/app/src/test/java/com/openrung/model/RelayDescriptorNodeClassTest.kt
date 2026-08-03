package com.openrung.model

import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The connect-time stamp's two-value collapse (contract §3: anything but "foundation" is a
 * volunteer relay). Decode defaults for an ABSENT node_class are covered by
 * WssFallbackPolicyTest; this pins the normalization of present-but-unknown values.
 */
class RelayDescriptorNodeClassTest {
    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `normalizes the two contract classes to themselves`() {
        assertEquals(
            RelayConstants.NODE_CLASS_FOUNDATION,
            relayWithNodeClass(""""node_class":"foundation",""").normalizedNodeClass(),
        )
        assertEquals(
            RelayConstants.NODE_CLASS_VOLUNTEER,
            relayWithNodeClass(""""node_class":"volunteer",""").normalizedNodeClass(),
        )
    }

    @Test
    fun `collapses unknown future classes and blank values to volunteer`() {
        assertEquals(
            RelayConstants.NODE_CLASS_VOLUNTEER,
            relayWithNodeClass(""""node_class":"sponsored",""").normalizedNodeClass(),
        )
        assertEquals(
            RelayConstants.NODE_CLASS_VOLUNTEER,
            relayWithNodeClass(""""node_class":"",""").normalizedNodeClass(),
        )
        // Absent on the wire: the decode default is volunteer, and normalization keeps it.
        assertEquals(
            RelayConstants.NODE_CLASS_VOLUNTEER,
            relayWithNodeClass("").normalizedNodeClass(),
        )
    }

    private fun relayWithNodeClass(extra: String): RelayDescriptor =
        json.decodeFromString<RelayDescriptor>(
            """
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
            """.trimIndent(),
        )
}
