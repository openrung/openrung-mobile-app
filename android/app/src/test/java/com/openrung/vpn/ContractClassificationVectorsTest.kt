package com.openrung.vpn

import android.app.Application
import android.system.ErrnoException
import android.system.OsConstants
import com.openrung.net.WssTicketStatusException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import javax.net.ssl.SSLHandshakeException

/**
 * The Kotlin half of the shared failure-classification contract.
 *
 * The rows come from testdata/contract/classification.json, vendored from openrung/openrung and
 * checked against the pinned ref by `npm run contract:check`. Since the classifier policy moved
 * into the shared Go implementation behind the libbox binding, this suite pins the adapter half:
 * the platform exception built for each row must extract to the exact binding input recorded in
 * testdata/classification-binding-inputs.json. The other half — those same inputs classifying to
 * each row's expected token through the real binding — runs in android/punchbridge's Go tests
 * (failure_binding_test.go), so the two suites compose into the rows running end-to-end against
 * the one classifier every OpenRung client shares. A JVM test cannot load the gomobile engine,
 * which is why the chain is split exactly at the binding's wire format.
 *
 * Runs under Robolectric for the same reason [FailureClassifierErrnoTest] does: a stubbed
 * `android.jar` reports every `OsConstants` value as 0 and has no working [ErrnoException].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class ContractClassificationVectorsTest {

    private companion object {
        /** The version this suite was written against; a bump upstream means revisiting it. */
        const val EXPECTED_VERSION = 2

        /** This suite's identifier in the file's `suites` declaration. */
        const val SUITE = "kotlin"

        /**
         * Set by the Gradle unit-test task (see `testOptions.unitTests` in build.gradle) so the
         * path does not depend on a working directory.
         */
        val vectorDir: File = File(
            requireNotNull(System.getProperty("openrung.contractVectors")) {
                "openrung.contractVectors is unset; the Gradle unit-test task should supply it"
            },
        )

        /** The repo-owned binding-input fixture lives beside the vendored contract directory. */
        val bindingInputFile: File = File(vectorDir.parentFile, "classification-binding-inputs.json")
    }

    private val vectors: JsonObject =
        Json.parseToJsonElement(File(vectorDir, "classification.json").readText()).jsonObject

    private val bindingInputs: JsonObject =
        Json.parseToJsonElement(bindingInputFile.readText()).jsonObject

    private fun string(owner: JsonObject, key: String): String? =
        owner[key]?.jsonPrimitive?.contentOrNull

    /** The suites that must run a row: the kind's list, narrowed by the row's own when it has one. */
    private fun suitesFor(row: JsonObject): List<String> {
        val own = row["suites"]?.jsonArray?.map { it.jsonPrimitive.content }
        if (own != null) return own
        val kind = string(row, "kind")
        return vectors["kinds"]!!.jsonObject[kind]!!.jsonObject["suites"]!!
            .jsonArray.map { it.jsonPrimitive.content }
    }

    @Test
    fun `runs the version and the suite it was written for`() {
        assertEquals(EXPECTED_VERSION, vectors["version"]!!.jsonPrimitive.int)
        assertEquals(EXPECTED_VERSION, bindingInputs["contract_version"]!!.jsonPrimitive.int)
        assertTrue(
            "the file must declare this suite as a consumer",
            vectors["suites"]!!.jsonArray.map { it.jsonPrimitive.content }.contains(SUITE),
        )
    }

    @Test
    fun `every row this suite claims extracts to the shared binding input`() {
        var ran = 0
        vectors["cases"]!!.jsonArray.forEach { element ->
            val row = element.jsonObject
            val id = string(row, "id")!!
            if (!suitesFor(row).contains(SUITE)) return@forEach
            // Winsock numbers only a Windows network stack produces; Android never sees them.
            if (string(row, "platform") == "windows") return@forEach

            val error = errorFor(row) ?: return@forEach
            ran++
            if (error.value == null) {
                // The one adapter-owned rule: a null error never reaches the binding.
                assertEquals(id, "", FailureClassifier.classify(null))
                return@forEach
            }
            assertEquals(
                id,
                expectedBindingInput(id),
                Json.parseToJsonElement(FailureClassifier.describeFailure(error.value)).jsonObject,
            )
        }
        // A suite that silently matched no row would pass while asserting nothing.
        assertTrue("no rows ran; the vectors or the kind mapping changed shape", ran >= 20)
    }

    /**
     * The fixture entry for [id], with `errno_symbol` resolved to this platform's number via
     * [OsConstants] — the same transform the Go and Swift suites apply on their platforms.
     */
    private fun expectedBindingInput(id: String): JsonObject {
        val entry = requireNotNull(bindingInputs["inputs"]!!.jsonObject[id]) {
            "$id: no binding-input fixture entry; add it to ${bindingInputFile.name}"
        }.jsonObject
        return buildJsonObject {
            entry.forEach { (key, value) ->
                if (key == "errno_symbol") {
                    put("errno", osConstant(value.jsonPrimitive.content))
                } else {
                    put(key, value)
                }
            }
        }
    }

    /**
     * Wraps the built error so a legitimately null error (the `none` kind) is distinguishable from
     * a kind this suite does not construct.
     */
    private class Built(val value: Throwable?)

    private fun errorFor(row: JsonObject): Built? {
        val input = row["input"]!!.jsonObject
        val wrapped = input["wrapped"]?.jsonPrimitive?.booleanOrNull == true
        // The shape the connect pipeline actually produces: the real cause under a generic wrapper.
        fun wrap(error: Throwable): Throwable =
            if (wrapped) IllegalStateException("relay is not reachable", error) else error

        return when (string(row, "kind")) {
            "none" -> Built(null)
            "cancellation" -> Built(wrap(CancellationException("user stopped the tunnel")))
            "selection" -> Built(wrap(selectionSentinel(string(input, "sentinel")!!)))
            "http_status" -> Built(
                wrap(WssTicketStatusException(input["status"]!!.jsonPrimitive.int, null)),
            )
            "errno" -> Built(errnoError(string(input, "symbol")!!, wrapped))
            "dns" -> when (string(input, "subkind")) {
                "not_found" -> Built(wrap(UnknownHostException("Unable to resolve host")))
                else -> null
            }
            "tls" -> Built(wrap(SSLHandshakeException("TLS failure")))
            "permission" -> Built(wrap(SecurityException("VPN permission revoked")))
            "process_exit" -> Built(wrap(EngineStartException("engine failed", null)))
            "timeout" -> Built(wrap(SocketTimeoutException("connect timed out")))
            "unrecognized" -> Built(RuntimeException(string(input, "message")))
            // deadline and wss_reason are declared go-only; suitesFor already filtered them out.
            else -> null
        }
    }

    private fun selectionSentinel(sentinel: String): Throwable = when (sentinel) {
        "no_relays_available" -> RelaySelectionException.NoRelaysAvailable("broker returned no relays")
        "relay_not_in_list" -> RelaySelectionException.RelayNotInList("target relay not offered")
        "no_relay_in_country" -> RelaySelectionException.NoRelayInCountry("no relay in country")
        "no_usable_relay" -> RelaySelectionException.NoUsableRelay("no usable relay")
        else -> throw AssertionError("unknown selection sentinel $sentinel")
    }

    private fun errnoError(symbol: String, wrapped: Boolean): Throwable {
        val errno = ErrnoException("connect", osConstant(symbol))
        // Android surfaces a socket errno as a ConnectException carrying it as the cause.
        return if (wrapped) {
            ConnectException("failed to connect to /203.0.113.10:443").apply { initCause(errno) }
        } else {
            errno
        }
    }

    private fun osConstant(symbol: String): Int = when (symbol) {
        "ECONNREFUSED" -> OsConstants.ECONNREFUSED
        "ECONNRESET" -> OsConstants.ECONNRESET
        "ENETUNREACH" -> OsConstants.ENETUNREACH
        "EHOSTUNREACH" -> OsConstants.EHOSTUNREACH
        "ETIMEDOUT" -> OsConstants.ETIMEDOUT
        "EACCES" -> OsConstants.EACCES
        "EPERM" -> OsConstants.EPERM
        "EPIPE" -> OsConstants.EPIPE
        else -> throw AssertionError("unknown errno symbol $symbol")
    }
}
