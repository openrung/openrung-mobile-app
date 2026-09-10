package com.openrung.vpn

import android.app.Application
import com.openrung.state.ConnectionStatus
import com.openrung.state.OpenRungStatusStore
import com.openrung.net.SingBoxBindingFixtures
import kotlinx.serialization.json.*
import io.nekohasekai.libbox.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.Executor

/** OS owner ordering; the JNI engine itself is exercised by BoundEngineSequenceTest. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], application = Application::class)
class EngineProcessHostTest {
    private class Queue : Executor {
        val pending = ArrayDeque<Runnable>()
        override fun execute(task: Runnable) { pending.addLast(task) }
        fun drain() { while (pending.isNotEmpty()) pending.removeFirst().run() }
    }
    private class Engine : OpenRungEngine {
        val calls = mutableListOf<String>()
        var complete = true
        lateinit var listener: OpenRungEngineListener
        override fun start(url: String?, country: String?, relay: String?) { calls.add("start:$relay") }
        override fun stop(budget: Long) { calls.add("stop") }
        override fun teardownComplete() = complete
        override fun disconnect() { calls.add("disconnect") }
        override fun pause() { calls.add("pause") }
        override fun resume() { calls.add("resume") }
        override fun networkChanged(up: Boolean, fingerprint: String?, dns: String?) { calls.add("network") }
        override fun stateJSON() = "{}"
        fun state(sequence: Int, value: String) = listener.onEvent(
            """{"version":1,"sequence":$sequence,"kind":"state","payload":{"Status":"$value"}}""",
        )
    }

    @Test fun `reapply cannot resurrect a tunnel after a later disconnect`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        var constructions = 0
        val host = EngineProcessHost(queue) { _, _, listener -> constructions++; engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, "relay-a"); queue.drain()
        engine.state(1, "connected"); queue.drain()
        host.reapply(service, 2)
        host.stop(service, 3)
        queue.drain()
        assertEquals(1, constructions)
        assertEquals(listOf("start:relay-a", "stop", "start:relay-a", "stop"), engine.calls.filter { it == "stop" || it.startsWith("start:") })
        assertEquals(ConnectionStatus.DISCONNECTED, OpenRungStatusStore.uiState.value.status)
    }

    @Test fun `queued callback from old connection cannot fail the new owner`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, "relay-a"); queue.drain()
        host.connect(service, 2, "https://example.org", null, "relay-b")
        engine.state(1, "failed") // Captures the old dispatcher attachment, delivered after connect.
        queue.drain()
        engine.state(2, "connected"); queue.drain()
        assertEquals(ConnectionStatus.CONNECTED, OpenRungStatusStore.uiState.value.status)
        assertEquals(1, engine.calls.count { it == "stop" })
        host.stop(service, 3); queue.drain()
    }

    @Test fun `incomplete teardown refuses successor and retains original protector owner`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, "relay-a"); queue.drain()
        engine.complete = false
        host.connect(service, 2, "https://example.org", null, "relay-b"); queue.drain()
        assertEquals(listOf("start:relay-a"), engine.calls.filter { it.startsWith("start:") })
        assertEquals(ConnectionStatus.FAILED, OpenRungStatusStore.uiState.value.status)
        engine.complete = true
        host.stop(service, 3); queue.drain()
    }

    @Test fun `wake publishes current network before resuming engine`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, null); queue.drain()
        engine.calls.clear()
        host.pause(service, true); host.pause(service, false); queue.drain()
        assertEquals(listOf("pause", "network", "resume"), engine.calls)
        host.stop(service, 2); queue.drain()
    }

    @Test fun `missing native artifact reports startup failure instead of crashing service`() {
        val queue = Queue()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, _ -> throw UnsatisfiedLinkError("missing libbox") }
        host.connect(service, 1, "https://example.org", null, null); queue.drain()
        assertEquals(ConnectionStatus.FAILED, OpenRungStatusStore.uiState.value.status)
        assertEquals("missing libbox", OpenRungStatusStore.uiState.value.lastError)
        host.destroyed(service, 1); queue.drain()
        assertEquals(ConnectionStatus.FAILED, OpenRungStatusStore.uiState.value.status)
    }

    @Test fun `service replacement reuses engine and ignores old destruction`() {
        val queue = Queue(); val engine = Engine(); var created = 0
        val first = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val second = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> created++; engine.apply { this.listener = listener } }
        host.connect(first, 1, "https://example.org", null, "relay-a"); queue.drain()
        host.connect(second, 1, "https://example.org", null, "relay-b"); queue.drain()
        host.destroyed(first, 1); queue.drain()
        assertEquals(1, created)
        assertEquals(1, engine.calls.count { it == "stop" })
        host.stop(second, 2); queue.drain()
    }

    @Test fun `cold service restart clears unfinished persisted status`() {
        val queue = Queue()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, _ -> error("restart must not construct an engine") }
        OpenRungStatusStore.setStatus(ConnectionStatus.CONNECTING)
        host.stop(service, 1); queue.drain()
        assertEquals(ConnectionStatus.DISCONNECTED, OpenRungStatusStore.uiState.value.status)
    }

    @Test fun `mobile host settings retain native builder inputs and refresh persisted bypass`() {
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val settings = Json.parseToJsonElement(service.settingsJSON()).jsonObject
        val original = SingBoxBindingFixtures.input("android-tun")
        for (key in listOf("mtu", "tunnel_ipv4_address", "tunnel_ipv6_address", "probe_domain_suffixes", "route_find_process")) {
            assertEquals(key, original[key], settings[key])
        }
        assertFalse(settings.containsKey("relay"))
        SplitTunnelStore.writeAndReportEffectiveChange(service,
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":[],"country_source":"manual","excluded_packages":[]}""")
        val refreshed = Json.parseToJsonElement(service.settingsJSON()).jsonObject
        assertEquals(true, refreshed["split_tunnel"]!!.jsonObject["bypass_lan"]!!.jsonPrimitive.boolean)
    }
}
