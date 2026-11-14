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
 * openrung and not here, is that the primary the app configures is still one of the canonical ones.
 *
 * Plain JUnit: no `android.system` values are involved, so Robolectric is unnecessary.
 */
class ContractBrokerFrontsTest {

    private companion object {
        const val EXPECTED_VERSION = 3
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
    fun `the configured primary is a canonical front`() {
        val fronts = canonicalFronts
        assertTrue(
            "${AppConfig.DEFAULT_BROKER_URL} is not in the canonical front list $fronts",
            fronts.contains(AppConfig.DEFAULT_BROKER_URL),
        )
    }
}
