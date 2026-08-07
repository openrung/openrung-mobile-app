package com.openrung.net

import com.openrung.model.RelayDescriptor
import com.openrung.state.ConnectionStatus
import com.openrung.vpn.publishConnectedAfterVerifiedStartup
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.ConnectException
import java.net.UnknownHostException

/** Generated-config integration coverage for the geosite-cn connectivity-probe regression. */
class InternetProbeChinaBypassIntegrationTest {
    @Test
    fun `direct internet cannot publish connected when China bypass is on and proxy is dead`() = runTest {
        val network = RoutingAwareNetwork(
            configuration = chinaBypassConfiguration(),
            directInternetAvailable = true,
            proxyAvailable = false,
        )
        val publishedStatuses = mutableListOf<ConnectionStatus>()

        val failure = runCatching {
            publishConnectedAfterVerifiedStartup(
                startAndVerify = {
                    runFreshDnsHttpsProbe(
                        resolveFreshDns = { network.resolveProbe() },
                        probeHttps = { network.requestProbeHttps() },
                    )
                },
                publishConnected = { publishedStatuses += ConnectionStatus.CONNECTED },
            )
        }.exceptionOrNull()

        assertTrue(failure is UnknownHostException)
        assertFalse(publishedStatuses.contains(ConnectionStatus.CONNECTED))
        assertEquals(listOf(SimulatedPath.PROXY), network.selectedPaths)
    }

    @Test
    fun `working proxy passes startup with China bypass enabled`() = runTest {
        val network = RoutingAwareNetwork(
            configuration = chinaBypassConfiguration(),
            directInternetAvailable = true,
            proxyAvailable = true,
        )
        val publishedStatuses = mutableListOf<ConnectionStatus>()

        publishConnectedAfterVerifiedStartup(
            startAndVerify = {
                runFreshDnsHttpsProbe(
                    resolveFreshDns = { network.resolveProbe() },
                    probeHttps = { network.requestProbeHttps() },
                )
            },
            publishConnected = { publishedStatuses += ConnectionStatus.CONNECTED },
        )

        assertEquals(listOf(ConnectionStatus.CONNECTED), publishedStatuses)
        assertEquals(
            listOf(SimulatedPath.PROXY, SimulatedPath.PROXY),
            network.selectedPaths,
        )
    }

    private fun chinaBypassConfiguration(): JsonObject = SingBoxConfiguration(
        relay = relay(),
        splitTunnel = SplitTunnelRules(
            bypassLan = false,
            bypassCountries = listOf("cn"),
            excludedPackages = emptyList(),
            ruleSetDirectory = "/data/user/0/rulesets",
        ),
    ).makeJsonObject()

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

private enum class SimulatedPath {
    DIRECT,
    PROXY,
}

/**
 * Treats the probe hostname as a geosite-cn member, matching the production regression. It walks
 * generated rules in order; usable direct internet is intentionally available so only the exact
 * forced-proxy rules can keep a dead proxy from looking healthy.
 */
private class RoutingAwareNetwork(
    private val configuration: JsonObject,
    private val directInternetAvailable: Boolean,
    private val proxyAvailable: Boolean,
) {
    val selectedPaths = mutableListOf<SimulatedPath>()

    fun resolveProbe() {
        val path = selectedDnsPath()
        selectedPaths += path
        if (!isAvailable(path)) throw UnknownHostException("simulated probe DNS path is unavailable")
    }

    fun requestProbeHttps() {
        val path = selectedRoutePath()
        selectedPaths += path
        if (!isAvailable(path)) throw ConnectException("simulated probe HTTPS path is unavailable")
    }

    private fun selectedDnsPath(): SimulatedPath {
        val rules = configuration["dns"]!!.jsonObject["rules"]!!.jsonArray
        for (element in rules) {
            val rule = element.jsonObject
            if (rule.matchesProbeDomain()) {
                val server = rule["server"]?.jsonPrimitive?.content.orEmpty()
                if (server.startsWith("dns-proxy-")) return SimulatedPath.PROXY
            }
            if (rule.matchesChinaRuleSet()) return SimulatedPath.DIRECT
        }
        return SimulatedPath.DIRECT
    }

    private fun selectedRoutePath(): SimulatedPath {
        val route = configuration["route"]!!.jsonObject
        for (element in route["rules"]!!.jsonArray) {
            val rule = element.jsonObject
            if (rule.matchesProbeDomain()) {
                return if (rule["outbound"]?.jsonPrimitive?.content == "proxy") {
                    SimulatedPath.PROXY
                } else {
                    SimulatedPath.DIRECT
                }
            }
            if (rule.matchesChinaRuleSet()) return SimulatedPath.DIRECT
        }
        return if (route["final"]!!.jsonPrimitive.content == "proxy") {
            SimulatedPath.PROXY
        } else {
            SimulatedPath.DIRECT
        }
    }

    private fun JsonObject.matchesProbeDomain(): Boolean =
        this["domain"]?.jsonArray?.any {
            it.jsonPrimitive.content == SingBoxConfiguration.CONNECTIVITY_PROBE_HOST
        } == true

    private fun JsonObject.matchesChinaRuleSet(): Boolean =
        this["rule_set"]?.jsonArray?.any { it.jsonPrimitive.content == "geosite-cn" } == true

    private fun isAvailable(path: SimulatedPath): Boolean = when (path) {
        SimulatedPath.DIRECT -> directInternetAvailable
        SimulatedPath.PROXY -> proxyAvailable
    }
}
