package com.openrung.vpn

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.nekohasekai.libbox.Libbox
import kotlinx.serialization.json.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** A4 commands cross JNI into the tagged engine; expectations are asserted in Kotlin.
 * Only remote I/O, clocks and the tunnel process are scripted in the test-only AAR.
 */
@RunWith(AndroidJUnit4::class)
class BoundEngineSequenceTest {
    @Test fun allVendoredSequencesThroughTheAndroidDispatcher() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val vectors = Json.parseToJsonElement(instrumentation.context.assets.open("event_sequence.json")
            .bufferedReader().use { it.readText() }).jsonObject
        assertEquals(1, vectors["version"]!!.jsonPrimitive.int)
        for (scenario in vectors["scenarios"]!!.jsonArray.map { it.jsonObject }) {
            val queue = Executors.newSingleThreadExecutor()
            fun <T> onQueue(work: () -> T): T = queue.submit<T> { work() }.get(15, TimeUnit.SECONDS)
            val statuses = mutableListOf<String>()
            val notices = mutableListOf<JsonObject>()
            val invalid = mutableListOf<String>()
            val dispatcher = EngineEventDispatcher({ queue.execute(it) }, invalid::add)
            onQueue { dispatcher.attach { event ->
                when (event.kind) {
                    "state" -> event.payload.text("Status")?.let { if (statuses.lastOrNull() != it) statuses.add(it) }
                    "notice" -> notices.add(buildJsonObject {
                        put("kind", event.payload.text("Kind").orEmpty())
                        for ((source, target) in mapOf("RelayID" to "relay_id", "FromRelayID" to "from_relay_id", "FrontID" to "front_id")) {
                            event.payload.text(source)?.takeIf { it.isNotEmpty() }?.let { put(target, it) }
                        }
                        for ((source, target) in mapOf("Failures" to "failures", "Threshold" to "threshold")) {
                            event.payload[source]?.jsonPrimitive?.intOrNull?.takeIf { it != 0 }?.let { put(target, it) }
                        }
                    })
                }
            } }
            val directory = File(instrumentation.targetContext.cacheDir, "a4-${scenario.text("id")}").apply { mkdirs() }
            val harness = onQueue { Libbox.newOpenRungContractScenario(scenario.toString(), directory.path, dispatcher) }
            try {
                val engine = harness.engine()
                for (step in scenario["steps"]!!.jsonArray.map { it.jsonObject }) {
                    fun await(predicate: () -> Boolean) {
                        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(12)
                        while (!onQueue(predicate)) {
                            check(System.nanoTime() < deadline) { "${scenario.text("id")}: timed out at $step" }
                            Thread.sleep(5)
                        }
                    }
                    when (step.text("do")) {
                        "connect" -> onQueue { engine.start(harness.brokerURL(), "", "") }
                        "disconnect" -> onQueue { engine.disconnect() }
                        "shutdown" -> onQueue { engine.stop(step["flush_budget_ms"]?.jsonPrimitive?.long ?: 0) }
                        "network" -> onQueue { engine.networkChanged(step["up"]!!.jsonPrimitive.boolean, step.text("fingerprint").orEmpty(), "[]") }
                        "await_status" -> await { statuses.count { it == step.text("status") } >= (step["count"]?.jsonPrimitive?.int ?: 1) }
                        "await_notice" -> await { notices.count { it.text("kind") == step.text("kind") } >= (step["count"]?.jsonPrimitive?.int ?: 1) }
                        "crash_tunnel" -> harness.crashTunnel()
                        "await_ready_hold" -> harness.awaitReadyHold()
                        "release_ready" -> harness.releaseReady()
                        else -> error("Unknown A4 command: $step")
                    }
                }
                onQueue { engine.stop(1000) }
                val got = onQueue { buildJsonObject {
                    put("statuses", buildJsonArray { statuses.forEach { add(it) } })
                    put("notices", JsonArray(notices.toList()))
                    put("events", Json.parseToJsonElement(harness.eventsJSON()))
                } }
                assertEquals(scenario.text("id"), scenario["expect"], got)
                assertTrue(invalid.toString(), invalid.isEmpty())
            } finally {
                harness.close()
                onQueue { dispatcher.detach() }
                queue.shutdown()
                assertTrue(queue.awaitTermination(5, TimeUnit.SECONDS))
                directory.deleteRecursively()
            }
        }
    }
}
