package com.openrung.vpn

import com.openrung.model.RelayConstants
import com.openrung.model.RelayDescriptor
import com.openrung.model.WssFrontDescriptor
import java.util.concurrent.CancellationException
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class WssFallbackPolicyTest {
    private val fronts = listOf(
        WssFrontDescriptor(id = "front-a", url = "opaque-front-a", protocolVersion = 1),
        WssFrontDescriptor(id = "front-b", url = "opaque-front-b", protocolVersion = 1),
    )

    @Test
    fun `descriptor defaults legacy node class and decodes signed WSS fronts`() {
        val json = Json { ignoreUnknownKeys = true }

        val legacy = json.decodeFromString<RelayDescriptor>(descriptorJson())
        assertEquals(RelayConstants.NODE_CLASS_VOLUNTEER, legacy.nodeClass)
        assertTrue(legacy.wssFronts.isEmpty())

        val signed = json.decodeFromString<RelayDescriptor>(descriptorJson(
            """
            "node_class":"foundation",
            "wss_fronts":[
              {"id":"front-a","url":"wss://cdn.example.test/connect","protocol_version":1}
            ],
            """.trimIndent(),
        ))
        assertEquals(RelayConstants.NODE_CLASS_FOUNDATION, signed.nodeClass)
        assertEquals(
            listOf(
                WssFrontDescriptor(
                    id = "front-a",
                    url = "wss://cdn.example.test/connect",
                    protocolVersion = 1,
                ),
            ),
            signed.wssFronts,
        )

        val unknownNestedField = descriptorJson(
            """
            "node_class":"foundation",
            "wss_fronts":[
              {
                "id":"front-a",
                "url":"wss://cdn.example.test/connect",
                "protocol_version":1,
                "ticket":"must-not-be-discarded"
              }
            ],
            """.trimIndent(),
        )
        assertTrue(
            "unknown signed-front fields must fail before typed re-encoding",
            runCatching { json.decodeFromString<RelayDescriptor>(unknownNestedField) }.isFailure,
        )
    }

    @Test
    fun `eligible relay accepts omitted or direct transport`() {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.toList() })

        assertEquals(fronts, policy.supportedFronts(relay(transport = "")))
        assertEquals(fronts, policy.supportedFronts(relay(transport = " DIRECT ")))
    }

    @Test
    fun `structurally ineligible relays never reach front validator`() {
        var validatorCalls = 0
        val policy = WssFallbackPolicy(WssFrontSetValidator {
            validatorCalls++
            it
        })

        val ineligible = listOf(
            relay(nodeClass = RelayConstants.NODE_CLASS_VOLUNTEER),
            relay(transport = "tunnel"),
            relay(exitMode = "proxy"),
            relay(publicPort = 8443),
            relay(wssFronts = emptyList()),
        )
        ineligible.forEach { assertTrue(policy.supportedFronts(it).isEmpty()) }
        assertEquals(0, validatorCalls)
    }

    @Test
    fun `canonical unique sorted decision belongs to injected validator`() {
        val signedOrderRejected = WssFallbackPolicy(WssFrontSetValidator { it.reversed() })
        assertTrue(signedOrderRejected.supportedFronts(relay()).isEmpty())

        val validationFailure = WssFallbackPolicy(WssFrontSetValidator {
            throw IllegalArgumentException("Go validator rejected the fronts")
        })
        assertTrue(validationFailure.supportedFronts(relay()).isEmpty())

        // Kotlin does not interpret this URL-shaped field. The production Go validator does.
        val exactSignedList = WssFallbackPolicy(WssFrontSetValidator { it.toList() })
        assertEquals(fronts, exactSignedList.supportedFronts(relay()))
    }

    @Test
    fun `direct success short circuits validation ticketing and callbacks`() = runTest {
        var directCalls = 0
        val policy = WssFallbackPolicy(WssFrontSetValidator {
            fail("fronts must not be validated before direct Reality fails")
            it
        })

        val result = policy.connect(
            relay = relay(),
            attemptDirect = {
                directCalls++
                "direct"
            },
            attemptWss = {
                fail("WSS must not run after direct success")
                "wss"
            },
            onDirectFallback = { fail("fallback callback must not run") },
            onWssFailure = { _, _ -> fail("WSS failure callback must not run") },
        )

        assertEquals("direct", result)
        assertEquals(1, directCalls)
    }

    @Test
    fun `local configuration unknown and cancellation failures do not unlock WSS`() = runTest {
        val policy = WssFallbackPolicy(WssFrontSetValidator {
            fail("non-direct-path failures must not validate WSS fronts")
            it
        })
        val failures = listOf<Throwable>(
            LocalTunnelException("permission", SecurityException("VPN permission revoked")),
            IllegalArgumentException("invalid local configuration"),
        )

        failures.forEach { expected ->
            var wssCalls = 0
            val thrown = captureFailure {
                policy.connect<Unit>(
                    relay = relay(),
                    attemptDirect = { throw expected },
                    attemptWss = { wssCalls++ },
                    onDirectFallback = { fail("fallback callback must not run") },
                    onWssFailure = { _, _ -> fail("WSS callback must not run") },
                )
            }
            assertSame(expected, thrown)
            assertEquals(0, wssCalls)
        }

        val cancellation = CancellationException("network scope stopped")
        val wrappedCancellation = DirectPathException("dial", cancellation)
        var wssCalls = 0
        val thrown = captureFailure {
            policy.connect<Unit>(
                relay = relay(),
                attemptDirect = { throw wrappedCancellation },
                attemptWss = { wssCalls++ },
                onDirectFallback = { fail("fallback callback must not run") },
                onWssFailure = { _, _ -> fail("WSS callback must not run") },
            )
        }
        assertSame(cancellation, thrown)
        assertEquals(0, wssCalls)
    }

    @Test
    fun `typed direct failure tries exact fronts in signed order`() = runTest {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.toList() })
        val directFailure = DirectPathException("dial", IllegalStateException("remote reset"))
        val firstFailure = WssTransportException("dial", "front-a", IllegalStateException("CDN reset"))
        val events = mutableListOf<String>()

        val result = policy.connect(
            relay = relay(),
            attemptDirect = {
                events += "direct"
                throw directFailure
            },
            attemptWss = { front ->
                events += "wss:${front.id}"
                if (front.id == "front-a") throw firstFailure
                "front-b-success"
            },
            onDirectFallback = {
                assertSame(directFailure, it)
                events += "fallback"
            },
            onWssFailure = { front, error ->
                assertEquals(front.id, error.frontId)
                events += "failed:${front.id}"
            },
        )

        assertEquals("front-b-success", result)
        assertEquals(
            listOf("direct", "fallback", "wss:front-a", "failed:front-a", "wss:front-b"),
            events,
        )
    }

    @Test
    fun `noncanonical fronts preserve original direct failure`() = runTest {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.reversed() })
        val directFailure = DirectPathException("dial", IllegalStateException("remote reset"))
        var wssCalls = 0

        val thrown = captureFailure {
            policy.connect<Unit>(
                relay = relay(),
                attemptDirect = { throw directFailure },
                attemptWss = { wssCalls++ },
                onDirectFallback = { fail("ineligible fronts must not start fallback") },
                onWssFailure = { _, _ -> fail("WSS callback must not run") },
            )
        }

        assertSame(directFailure, thrown)
        assertEquals(0, wssCalls)
    }

    @Test
    fun `all WSS failures carry relay-health marker and per-front telemetry`() = runTest {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.toList() })
        val directFailure = DirectPathException("dial", IllegalStateException("remote reset"))
        val failures = fronts.map { front ->
            WssTransportException("dial", front.id, IllegalStateException("${front.id} reset"))
        }
        var directFallbacks = 0
        val recordedFronts = mutableListOf<String>()

        val thrown = captureFailure {
            policy.connect<Unit>(
                relay = relay(),
                attemptDirect = { throw directFailure },
                attemptWss = { front -> throw failures.first { it.frontId == front.id } },
                onDirectFallback = { directFallbacks++ },
                onWssFailure = { front, _ -> recordedFronts += front.id },
            )
        }

        assertTrue(thrown is RelayFailureAlreadyRecordedException)
        val marker = thrown as RelayFailureAlreadyRecordedException
        assertSame(directFailure, marker.directFailure)
        assertEquals(failures, marker.wssFailures)
        assertSame(failures.last(), marker.lastWssFailure)
        assertEquals(1, directFallbacks)
        assertEquals(fronts.map { it.id }, recordedFronts)
        assertTrue(relayFailureAlreadyRecorded(IllegalStateException("outer", marker)))
        assertFalse(relayFailureAlreadyRecorded(directFailure))
    }

    @Test
    fun `local failure during WSS aborts remaining fronts without transport penalty`() = runTest {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.toList() })
        val localFailure = LocalTunnelException("loopback", IllegalStateException("engine stopped"))
        val attempted = mutableListOf<String>()
        var wssFailureCallbacks = 0

        val thrown = captureFailure {
            policy.connect<Unit>(
                relay = relay(),
                attemptDirect = {
                    throw DirectPathException("dial", IllegalStateException("remote reset"))
                },
                attemptWss = { front ->
                    attempted += front.id
                    throw localFailure
                },
                onDirectFallback = {},
                onWssFailure = { _, _ -> wssFailureCallbacks++ },
            )
        }

        assertSame(localFailure, thrown)
        assertEquals(listOf("front-a"), attempted)
        assertEquals(0, wssFailureCallbacks)
    }

    private suspend fun captureFailure(block: suspend () -> Unit): Throwable {
        var thrown: Throwable? = null
        try {
            block()
        } catch (error: Throwable) {
            thrown = error
        }
        return thrown ?: throw AssertionError("expected block to fail")
    }

    private fun relay(
        nodeClass: String = RelayConstants.NODE_CLASS_FOUNDATION,
        transport: String = "",
        exitMode: String = RelayConstants.EXIT_MODE_DIRECT,
        publicPort: Int = 443,
        wssFronts: List<WssFrontDescriptor> = fronts,
    ): RelayDescriptor = RelayDescriptor(
        id = "relay-1",
        publicHost = "203.0.113.10",
        publicPort = publicPort,
        relayProtocol = RelayConstants.PROTOCOL_VLESS_REALITY_VISION,
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "reality-key",
        shortId = "abcd",
        serverName = "www.example.com",
        flow = RelayConstants.FLOW_VISION,
        exitMode = exitMode,
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        nodeClass = nodeClass,
        transport = transport,
        wssFronts = wssFronts,
        registeredAt = "2026-01-01T00:00:00Z",
        lastHeartbeatAt = "2026-01-01T00:00:00Z",
        expiresAt = "2027-01-01T00:00:00Z",
    )

    private fun descriptorJson(extra: String = ""): String = """
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
          "expires_at":"2027-01-01T00:00:00Z"
        }
    """.trimIndent()
}
