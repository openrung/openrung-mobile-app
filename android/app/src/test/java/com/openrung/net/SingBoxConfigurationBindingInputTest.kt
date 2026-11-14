package com.openrung.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The platform half of the sing-box builder contract: the engine settings Android hands
 * connectcore for each scenario must match that scenario's checked-in binding input, minus the
 * `relay` and loopback-bridge fields connectcore supplies itself. The other half — those inputs
 * building to the frozen goldens through the real binding — runs in `android/punchbridge`'s Go
 * tests, and the structural suites here assert against the goldens.
 */
class SingBoxConfigurationBindingInputTest {

    /** The split-tunnel rules for each scenario; bridge scenarios are connectcore-owned. */
    private fun rulesFor(scenario: String): SplitTunnelRules? {
        val directory = "/data/user/0/rulesets"
        return when (scenario) {
            "android-tun" -> null
            "android-split-empty" -> SplitTunnelRules(false, emptyList(), emptyList(), "")
            "android-split-lan" -> SplitTunnelRules(true, emptyList(), emptyList(), directory)
            "android-split-ir" -> SplitTunnelRules(false, listOf("ir"), emptyList(), directory)
            "android-split-cn" -> SplitTunnelRules(false, listOf("cn"), emptyList(), directory)
            "android-split-ir-cn-lan" -> SplitTunnelRules(true, listOf("ir", "cn"), emptyList(), directory)
            "android-split-packages" -> SplitTunnelRules(
                false,
                emptyList(),
                listOf("com.tencent.mm", "org.telegram.messenger"),
                "",
            )
            else -> throw AssertionError(
                "no rules for scenario $scenario; add them here when adding a fixture",
            )
        }
    }

    private fun settings(rules: SplitTunnelRules?, debug: Boolean = false): JsonObject =
        Json.parseToJsonElement(SingBoxConfiguration.engineSettingsJson(rules, debug)).jsonObject

    @Test
    fun `every android scenario's settings match its checked-in binding input`() {
        val scenarios = SingBoxBindingFixtures.scenarios("android").filterNot { it.endsWith("bridge") }
        assertTrue("no android scenarios found; the fixture directory changed shape", scenarios.size >= 5)
        scenarios.forEach { scenario ->
            val expected = JsonObject(SingBoxBindingFixtures.input(scenario) - "relay")
            assertEquals(scenario, expected, settings(rulesFor(scenario)))
        }
    }

    @Test
    fun `debug builds request the info log level`() {
        assertEquals("info", settings(null, debug = true)["log_level"]!!.jsonPrimitive.content)
    }
}
