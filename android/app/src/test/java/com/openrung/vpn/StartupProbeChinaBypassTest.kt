package com.openrung.vpn

import com.openrung.model.RelayConstants
import com.openrung.model.RelayDescriptor
import com.openrung.model.WssFrontDescriptor
import com.openrung.net.DnsProbe
import com.openrung.net.DnsResolverRotation
import com.openrung.net.InternetProbeResult
import com.openrung.net.ProbeTargets
import com.openrung.net.SingBoxConfiguration
import com.openrung.net.SplitTunnelRules
import com.openrung.net.TunnelDnsTransport
import com.openrung.net.TunnelHttpProbe
import com.openrung.net.TunnelPathProbe
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicLong
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.net.SocketTimeoutException

/**
 * Integration-style startup tests for the confirmed China-bypass regression: geosite-cn contains
 * www.gstatic.com, so before the probe pins a dead proxy still yielded a passing probe over the
 * direct path and the app published CONNECTED.
 *
 * These run the REAL seams — the WSS fallback ladder, the startup guard race, the startup
 * classification ([verifyStartupTunnelPath], which alone authorizes success), the composite
 * fresh-DNS + HTTPS probe, resolver rotation, and the real cn-bypass configuration. Fakes exist
 * only at the two socket boundaries, which is precisely what a dead or working proxy controls:
 * with the emitted config, ALL probe DNS and HTTPS flows traverse the proxy (asserted below and
 * in SingBoxConfigurationDnsTest), so "proxy dead + direct internet fine" means both boundaries
 * time out, and "proxy working" means both answer.
 */
class StartupProbeChinaBypassTest {
    @Test
    fun `dead proxy with china bypass and working direct internet never connects`() = runBlocking {
        val rotation = DnsResolverRotation()
        val connected = mutableListOf<String>()
        val events = mutableListOf<String>()
        val serversUsed = mutableListOf<List<String>>()

        var thrown: RelayFailureAlreadyRecordedException? = null
        try {
            connectLadder(
                relay = relay(),
                rotation = rotation,
                dnsTransport = deadProxyDnsTransport(),
                httpProbe = deadProxyHttpProbe(),
                onConnected = { connected.add(it) },
                events = events,
                serversUsed = serversUsed,
            )
            fail("startup must fail when every probe path is proxied and the proxy is dead")
        } catch (error: RelayFailureAlreadyRecordedException) {
            thrown = error
        }

        // CONNECTED must never have been published, on any transport rung.
        assertTrue(connected.isEmpty())
        assertEquals(STARTUP_STAGE_DNS_PROBE, thrown!!.directFailure.stage)
        assertEquals(listOf("direct", "direct", "fallback", "wss:front-a", "wss:front-b"), events)
        // Real resolver failover: the same-relay retry and each later rung led with the
        // alternate resolver of the order that had just failed.
        assertEquals(
            listOf(
                listOf("1.1.1.1", "8.8.8.8"),
                listOf("8.8.8.8", "1.1.1.1"),
                listOf("1.1.1.1", "8.8.8.8"),
                listOf("8.8.8.8", "1.1.1.1"),
            ),
            serversUsed,
        )
    }

    @Test
    fun `working proxy with china bypass connects exactly once`() = runBlocking {
        val rotation = DnsResolverRotation()
        val connected = mutableListOf<String>()
        val events = mutableListOf<String>()

        val result = connectLadder(
            relay = relay(),
            rotation = rotation,
            dnsTransport = workingProxyDnsTransport(),
            httpProbe = workingProxyHttpProbe(),
            onConnected = { connected.add(it) },
            events = events,
            serversUsed = mutableListOf(),
        )

        assertEquals("direct", result)
        assertEquals(listOf("direct"), connected)
        // A healthy resolver path must not rotate anything.
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), rotation.currentServers())
    }

    @Test
    fun `china bypass config keeps every probe flow on the proxy`() {
        // The premise the socket-boundary fakes rest on: with cn bypass enabled, probe DNS is
        // answered only via the proxied DoH resolver and probe HTTPS routes only to the proxy.
        val config = SingBoxConfiguration(
            relay(),
            splitTunnel = SplitTunnelRules(
                bypassLan = false,
                bypassCountries = listOf("cn"),
                excludedPackages = emptyList(),
                ruleSetDirectory = "/data/user/0/rulesets",
            ),
        ).makeJsonObject()

        val dns = config["dns"]!!.jsonObject
        val probeDnsRule = dns["rules"]!!.jsonArray.first().jsonObject
        assertEquals(
            ProbeTargets.RULE_DOMAIN_SUFFIXES,
            probeDnsRule["domain_suffix"]!!.jsonArray.map { it.jsonPrimitive.content },
        )
        val probeDnsServerTag = probeDnsRule["server"]!!.jsonPrimitive.content
        val probeDnsServer = dns["servers"]!!.jsonArray
            .map { it.jsonObject }
            .first { it["tag"]!!.jsonPrimitive.content == probeDnsServerTag }
        assertEquals("proxy", probeDnsServer["detour"]!!.jsonPrimitive.content)
        assertEquals("https", probeDnsServer["type"]!!.jsonPrimitive.content)

        val routeRules = config["route"]!!.jsonObject["rules"]!!.jsonArray.map { it.jsonObject }
        val probeRouteIndex = routeRules.indexOfFirst { it.containsKey("domain_suffix") }
        val bypassIndex = routeRules.indexOfFirst {
            it["outbound"]?.jsonPrimitive?.content == "direct"
        }
        assertEquals("proxy", routeRules[probeRouteIndex]["outbound"]!!.jsonPrimitive.content)
        assertTrue(probeRouteIndex in 1 until bypassIndex)
    }

    /**
     * The service's connect rung for one relay, on the production seams: the WSS fallback policy
     * drives direct → WSS attempts; each attempt races the composite probe against engine stop
     * via [verifyStartupTunnelPath] and only a returned probe result reaches [onConnected] — the
     * exact gate in front of OpenRungStatusStore.setStatus(CONNECTED). The direct rung retries
     * once with the rotated resolver, mirroring attemptDirectCandidate.
     */
    private suspend fun connectLadder(
        relay: RelayDescriptor,
        rotation: DnsResolverRotation,
        dnsTransport: TunnelDnsTransport,
        httpProbe: TunnelHttpProbe,
        onConnected: (String) -> Unit,
        events: MutableList<String>,
        serversUsed: MutableList<List<String>>,
    ): String {
        val policy = WssFallbackPolicy(WssFrontSetValidator { it.toList() })

        suspend fun verifyRung(transport: String, frontId: String?): String {
            val servers = rotation.currentServers()
            serversUsed += servers
            // The clock must advance per look or DnsProbe.verify()'s real deadline never
            // expires against a dead transport (the runTest/SystemClock pitfall, inverted).
            val clock = AtomicLong(0)
            verifyStartupTunnelPath(
                probe = {
                    TunnelPathProbe(
                        DnsProbe(dnsTransport, elapsedRealtime = { clock.getAndAdd(2_000) }),
                        httpProbe,
                    ).verify()
                },
                awaitUnexpectedEngineStop = { awaitCancellation() },
                wssFrontId = frontId,
                onDnsPathFailure = { rotation.noteDnsPathFailure(servers) },
            )
            onConnected(transport)
            return transport
        }

        return policy.connect(
            relay = relay,
            attemptDirect = {
                var spareResolvers = rotation.resolverCount - 1
                var result: String? = null
                while (result == null) {
                    events += "direct"
                    try {
                        result = verifyRung("direct", frontId = null)
                    } catch (error: DirectPathException) {
                        if (error.stage != STARTUP_STAGE_DNS_PROBE || spareResolvers <= 0) {
                            throw error
                        }
                        spareResolvers--
                    }
                }
                result
            },
            attemptWss = { front ->
                events += "wss:${front.id}"
                verifyRung("wss", frontId = front.id)
            },
            onDirectFallback = { events += "fallback" },
            onWssFailure = { _, _ -> },
        )
    }

    /** Dead proxy: probe DNS is pinned through the proxied DoH resolver, so nothing answers. */
    private fun deadProxyDnsTransport() = TunnelDnsTransport {
        throw SocketTimeoutException("no DNS response through the tunnel")
    }

    /** Dead proxy: every HTTPS probe endpoint is route-pinned to the proxy, so nothing answers. */
    private fun deadProxyHttpProbe() = object : TunnelHttpProbe {
        override suspend fun verify(): InternetProbeResult =
            throw SocketTimeoutException("probe endpoints unreachable through the tunnel")

        override suspend fun verifyOnce(): InternetProbeResult = verify()
    }

    private fun workingProxyDnsTransport() = TunnelDnsTransport { query ->
        byteArrayOf(query[0], query[1], 0x81.toByte(), 0x80.toByte(), 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private fun workingProxyHttpProbe() = object : TunnelHttpProbe {
        override suspend fun verify(): InternetProbeResult =
            InternetProbeResult(ProbeTargets.TUNNEL_PROBE_URLS.first(), 21)

        override suspend fun verifyOnce(): InternetProbeResult = verify()
    }

    private fun relay(): RelayDescriptor = RelayDescriptor(
        id = "relay-1",
        publicHost = "203.0.113.10",
        publicPort = 443,
        relayProtocol = RelayConstants.PROTOCOL_VLESS_REALITY_VISION,
        clientId = "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey = "reality-key",
        shortId = "abcd",
        serverName = "www.example.com",
        flow = RelayConstants.FLOW_VISION,
        exitMode = RelayConstants.EXIT_MODE_DIRECT,
        maxSessions = 8,
        maxMbps = 100,
        relayVersion = "1.0.0",
        nodeClass = RelayConstants.NODE_CLASS_FOUNDATION,
        transport = "",
        wssFronts = listOf(
            WssFrontDescriptor(id = "front-a", url = "opaque-front-a", protocolVersion = 1),
            WssFrontDescriptor(id = "front-b", url = "opaque-front-b", protocolVersion = 1),
        ),
        registeredAt = "2026-01-01T00:00:00Z",
        lastHeartbeatAt = "2026-01-01T00:00:00Z",
        expiresAt = "2027-01-01T00:00:00Z",
    )
}
