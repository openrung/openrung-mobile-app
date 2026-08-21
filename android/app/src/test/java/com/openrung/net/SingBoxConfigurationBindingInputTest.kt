package com.openrung.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The assembly half of the sing-box builder contract: the configuration each Android scenario
 * constructs must produce exactly the checked-in binding input for that scenario. The other half
 * — those inputs building to the frozen goldens through the real binding — runs in
 * `android/punchbridge`'s Go tests, and the structural suites here assert against the goldens.
 */
class SingBoxConfigurationBindingInputTest {

    /** The configuration whose assembly must reproduce each scenario's input file. */
    private fun configurationFor(scenario: String): SingBoxConfiguration {
        val relay = SingBoxBindingFixtures.relay()
        val directory = "/data/user/0/rulesets"
        return when (scenario) {
            "android-tun" -> SingBoxConfiguration(relay)
            "android-bridge" -> SingBoxConfiguration(relay, bridgeHost = "127.0.0.1", bridgePort = 54321)
            "android-split-empty" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(false, emptyList(), emptyList(), ""),
            )
            "android-split-lan" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(true, emptyList(), emptyList(), directory),
            )
            "android-split-ir" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(false, listOf("ir"), emptyList(), directory),
            )
            "android-split-cn" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(false, listOf("cn"), emptyList(), directory),
            )
            "android-split-ir-cn-lan" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(true, listOf("ir", "cn"), emptyList(), directory),
            )
            "android-split-ir-cn-lan-bridge" -> SingBoxConfiguration(
                relay,
                bridgeHost = "127.0.0.1",
                bridgePort = 54321,
                splitTunnel = SplitTunnelRules(true, listOf("ir", "cn"), emptyList(), directory),
            )
            "android-split-packages" -> SingBoxConfiguration(
                relay,
                splitTunnel = SplitTunnelRules(
                    false,
                    emptyList(),
                    listOf("com.tencent.mm", "org.telegram.messenger"),
                    "",
                ),
            )
            else -> throw AssertionError(
                "no construction for scenario $scenario; add it here when adding a fixture",
            )
        }
    }

    @Test
    fun `every android scenario assembles to its checked-in binding input`() {
        val scenarios = SingBoxBindingFixtures.scenarios("android")
        assertTrue("no android scenarios found; the fixture directory changed shape", scenarios.size >= 5)
        scenarios.forEach { scenario ->
            assertEquals(
                scenario,
                SingBoxBindingFixtures.input(scenario),
                Json.parseToJsonElement(configurationFor(scenario).bindingInputJson(debug = false)).jsonObject,
            )
        }
    }

    @Test
    fun `debug builds request the info log level`() {
        val assembled = Json.parseToJsonElement(
            SingBoxConfiguration(SingBoxBindingFixtures.relay()).bindingInputJson(debug = true),
        ).jsonObject
        assertEquals("info", assembled["log_level"]!!.jsonPrimitive.content)
    }

    @Test
    fun `a partial bridge is forwarded faithfully for the binding to reject`() {
        // The old generator rejected a partial bridge locally; that validation is the binding's
        // now (see the Go suite), so the assembly must not repair or drop the partial values.
        val hostOnly = Json.parseToJsonElement(
            SingBoxConfiguration(SingBoxBindingFixtures.relay(), bridgeHost = "127.0.0.1")
                .bindingInputJson(debug = false),
        ).jsonObject
        assertEquals("127.0.0.1", hostOnly["bridge_host"]!!.jsonPrimitive.content)
        assertFalse(hostOnly.containsKey("bridge_port"))

        val portOnly = Json.parseToJsonElement(
            SingBoxConfiguration(SingBoxBindingFixtures.relay(), bridgePort = 1234)
                .bindingInputJson(debug = false),
        ).jsonObject
        assertEquals(1234, portOnly["bridge_port"]!!.jsonPrimitive.content.toInt())
        assertFalse(portOnly.containsKey("bridge_host"))
    }
}
