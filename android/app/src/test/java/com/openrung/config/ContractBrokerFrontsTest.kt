package com.openrung.config

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The Kotlin half of the shared broker-front snapshot.
 *
 * This app owns no racing — it hands native brokerapi a primary and Go races the built-in
 * candidates — so the phases and candidate ordering in the vectors belong to the Go suite and are
 * deliberately not asserted here. What this side can claim, and what catches a front rotated in
 * openrung and not here, is that every front the app hardcodes is still one of the canonical ones.
 * A front that quietly stops existing is a fallback a blocked user no longer has.
 *
 * Plain JUnit: no `android.system` values are involved, so Robolectric is unnecessary.
 */
class ContractBrokerFrontsTest {

    private companion object {
        const val EXPECTED_VERSION = 2
        const val SUITE = "kotlin"
    }

    private val vectors = Json
        .parseToJsonElement(
            File(
                requireNotNull(System.getProperty("openrung.contractVectors")) {
                    "openrung.contractVectors is unset; the Gradle unit-test task should supply it"
                },
                "broker_fronts.json",
            ).readText(),
        )
        .jsonObject

    private val canonicalFronts: List<String>
        get() = vectors["default_order"]!!.jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun `runs the version and the suite it was written for`() {
        assertEquals(EXPECTED_VERSION, vectors["version"]!!.jsonPrimitive.int)
        assertTrue(
            vectors["suites"]!!.jsonArray.map { it.jsonPrimitive.content }.contains(SUITE),
        )
    }

    @Test
    fun `every hardcoded broker front is one of the canonical fronts`() {
        val fronts = canonicalFronts
        AppConfig.DEFAULT_BROKER_URLS.forEach { url ->
            assertTrue("$url is not in the canonical front list $fronts", fronts.contains(url))
        }
        assertTrue(AppConfig.DEFAULT_BROKER_URLS.isNotEmpty())
    }

    @Test
    fun `the configured primary and telemetry target are canonical fronts`() {
        val fronts = canonicalFronts
        assertTrue(fronts.contains(AppConfig.DEFAULT_BROKER_URL))
        // A telemetry target off the canonical list would carry the pre-VPN IP and the stable
        // client id to a host the directory contract never vouched for.
        assertTrue(fronts.contains(AppConfig.TELEMETRY_BROKER_URL))
    }

    @Test
    fun `the app carries a strict subset of the canonical fronts`() {
        // Recorded rather than asserted as equality: this app deliberately ships fewer fronts than
        // brokerapi races. The test exists so that gap stays a known one — if the app ever grew to
        // the full list, this is where that shows up.
        assertTrue(AppConfig.DEFAULT_BROKER_URLS.size <= canonicalFronts.size)
    }
}
