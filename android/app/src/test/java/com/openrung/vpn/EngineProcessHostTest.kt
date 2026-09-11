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
        var onStop: () -> Unit = {}
        lateinit var listener: OpenRungEngineListener
        override fun start(url: String?, country: String?, relay: String?) { calls.add("start:$relay") }
        override fun stop(budget: Long) { calls.add("stop"); onStop() }
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

    @Test fun `incomplete teardown terminates process and refuses all queued successors`() {
        for (trigger in listOf("stop", "connect", "failed")) {
            val queue = Queue(); val engine = Engine()
            val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
            var terminated = 0
            val host = EngineProcessHost(queue, { terminated++ }) { _, _, listener -> engine.apply { this.listener = listener } }
            host.connect(service, 1, "https://example.org", null, "relay-a"); queue.drain()
            engine.complete = false
            when (trigger) {
                "stop" -> host.stop(service, 2)
                "connect" -> host.connect(service, 2, "https://example.org", null, "relay-b")
                else -> engine.state(1, "failed")
            }
            queue.drain()
            assertEquals(trigger, 1, terminated)
            assertEquals(ConnectionStatus.FAILED, OpenRungStatusStore.uiState.value.status)
            assertTrue(service.networkAttributes().isEmpty()) // Observer was detached before termination.
            assertNull(host.sessionId)
            engine.complete = true // Even a late close cannot revive a process scheduled to die.
            host.connect(service, 3, "https://example.org", null, "relay-c")
            host.stop(service, 4); queue.drain()
            assertEquals(listOf("start:relay-a"), engine.calls.filter { it.startsWith("start:") })
            assertEquals(1, terminated)
        }
    }

    @Test fun `disconnecting is visible during the blocking stop`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, null); queue.drain()
        engine.state(1, "connected"); queue.drain()
        engine.onStop = { assertEquals(ConnectionStatus.DISCONNECTING, OpenRungStatusStore.uiState.value.status) }
        host.stop(service, 2); queue.drain()
        assertEquals(ConnectionStatus.DISCONNECTED, OpenRungStatusStore.uiState.value.status)
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
    @Test fun `connected location is sanitized localized and restored in notification`() {
        val queue = Queue(); val engine = Engine()
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        val host = EngineProcessHost(queue) { _, _, listener -> engine.apply { this.listener = listener } }
        host.connect(service, 1, "https://example.org", null, null); queue.drain()
        fun emit(sequence: Int, id: String, location: String) {
            val payload = buildJsonObject {
                put("Status", "connected"); put("RelayLabel", "\u202eevil legacy label")
                putJsonObject("Details") { put("RelayID", id); put("RelayName", "\u202efalcon"); put("LocationLabel", location) }
                putJsonArray("Recents") { add(buildJsonObject {
                    put("RelayID", "relay_a"); put("CountryCode", "JP"); put("Label", "\u202eunsafe recent")
                }) }
            }
            engine.listener.onEvent("""{"version":1,"sequence":$sequence,"kind":"state","payload":$payload}""")
            queue.drain()
        }
        emit(1, "relay_a", "\u202eTokyo, Japan")
        assertEquals("Tokyo, Japan", OpenRungStatusStore.uiState.value.relayLabel)
        assertEquals("falcon", OpenRungStatusStore.uiState.value.relayName)
        assertEquals("Tokyo, Japan", OpenRungStatusStore.uiState.value.recentRegions.first().label)
        val manager = service.getSystemService(android.app.NotificationManager::class.java)
        val notification = org.robolectric.Shadows.shadowOf(manager).getNotification(2001)
        assertEquals("Connected through Tokyo, Japan", notification.extras.getCharSequence(android.app.Notification.EXTRA_TEXT).toString())
        emit(2, "relay_b", "")
        assertEquals("Unknown location", OpenRungStatusStore.uiState.value.relayLabel)
        assertFalse(OpenRungStatusStore.uiState.value.recentRegions.any { it.relayId == "relay_b" })
        host.stop(service, 2); queue.drain()
    }

    @Test fun `candidate settings do not copy rule sets again`() {
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        SplitTunnelStore.writeAndReportEffectiveChange(service,
            """{"version":1,"enabled":true,"bypass_lan":true,"bypass_countries":[],"country_source":"manual","excluded_packages":[]}""")
        service.settingsJSON()
        val asset = java.io.File(service.filesDir, "libbox/rulesets/geosite-cn.srs")
        assertTrue(asset.isFile)
        assertTrue(asset.setLastModified(1000))
        repeat(10) { service.settingsJSON() }
        assertEquals(1000L, asset.lastModified())
    }

    @Test fun `failed teardown stops sticky service and notification before process termination`() {
        val service = Robolectric.buildService(OpenRungVpnService::class.java).create().get()
        service.startForeground(2001, android.app.Notification())
        service.terminateAfterFailedTeardown()
        org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
        val shadow = org.robolectric.Shadows.shadowOf(service)
        assertTrue(shadow.isStoppedBySelf)
        assertTrue(shadow.isForegroundStopped)
        assertTrue(shadow.notificationShouldRemoved)
        assertTrue(org.robolectric.shadows.ShadowProcess.wasKilled(android.os.Process.myPid()))
    }

}
