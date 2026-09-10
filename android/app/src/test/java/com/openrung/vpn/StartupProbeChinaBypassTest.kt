package com.openrung.vpn

import com.openrung.net.DnsProbe
import com.openrung.net.InternetProbeResult
import com.openrung.net.ProbeTargets
import com.openrung.net.SingBoxBindingFixtures
import com.openrung.net.TunnelDnsTransport
import com.openrung.net.TunnelHttpProbe
import com.openrung.net.TunnelPathProbe
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

/** Shipping China-bypass requirements retained from mobile main at 53e03d9.
 * Kotlin proves native DNS/HTTPS and route pins. Go mobile parity tests own
 * the CONNECTED gate and recovery policy after this cutover.
 */
class StartupProbeChinaBypassTest {
    @Test fun `dead proxy with china bypass cannot attest a working path`() = runBlocking {
        val clock = AtomicLong(0)
        var httpCalls = 0
        val probe = TunnelPathProbe(
            DnsProbe(deadProxyDnsTransport(), elapsedRealtime = { clock.getAndAdd(2_000) }),
            object : TunnelHttpProbe {
                override suspend fun verify(): InternetProbeResult { httpCalls++; return workingProxyHttpProbe().verify() }
                override suspend fun verifyOnce() = verify()
            },
        )
        try { probe.verify(); fail("dead proxy must fail fresh DNS") }
        catch (error: com.openrung.net.DnsPathUnverifiedException) { assertTrue(isGenuineRemoteDataPathFailure(error)) }
        assertEquals(0, httpCalls)
    }

    @Test fun `working proxy with china bypass attests both stages`() = runBlocking {
        val clock = AtomicLong(0)
        val result = TunnelPathProbe(
            DnsProbe(workingProxyDnsTransport(), elapsedRealtime = { clock.getAndIncrement() }),
            workingProxyHttpProbe(),
        ).verify()
        assertEquals(ProbeTargets.TUNNEL_PROBE_URLS.first(), result.endpoint)
    }

    @Test
    fun `china bypass config keeps every probe flow on the proxy`() {
        // The premise the socket-boundary fakes rest on: with cn bypass enabled, probe DNS is
        // answered only via the proxied DoH resolver and probe HTTPS routes only to the proxy.
        // The config is the frozen bound output for exactly this shape (see
        // SingBoxBindingFixtures and SingBoxConfigurationBindingInputTest).
        val config = SingBoxBindingFixtures.golden("android-split-cn")

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

}
