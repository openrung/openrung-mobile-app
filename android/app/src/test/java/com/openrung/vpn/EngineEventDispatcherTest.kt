package com.openrung.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class EngineEventDispatcherTest {
    private val pending = ArrayDeque<() -> Unit>()
    private val received = mutableListOf<EngineEvent>()
    private val invalid = mutableListOf<String>()
    private val dispatcher = EngineEventDispatcher({ pending.addLast(it) }, invalid::add)

    private fun event(sequence: Long, kind: String = "state") =
        """{"version":1,"sequence":$sequence,"kind":"$kind","payload":{"Status":"connecting"}}"""

    private fun drain() { while (pending.isNotEmpty()) pending.removeFirst().invoke() }

    @Test fun `Go callbacks enqueue and never call the platform inline`() {
        dispatcher.attach(received::add)
        dispatcher.onEvent(event(1))
        dispatcher.onEvent(event(2, "notice"))
        dispatcher.onEvent(event(3, "log"))
        assertTrue(received.isEmpty())
        drain()
        assertEquals(listOf(1L, 2L, 3L), received.map { it.sequence })
        assertEquals(listOf("state", "notice", "log"), received.map { it.kind })
    }

    @Test fun `queued callbacks from a destroyed owner cannot update a replacement`() {
        val old = mutableListOf<EngineEvent>()
        dispatcher.attach(old::add)
        dispatcher.onEvent(event(1))
        dispatcher.detach()
        dispatcher.onEvent(event(2))
        dispatcher.attach(received::add)
        dispatcher.onEvent(event(3))
        drain()
        assertTrue(old.isEmpty())
        assertEquals(listOf(3L), received.map { it.sequence })
    }

    @Test fun `rapid reconnect rejects old queued work even when receiver function is reused`() {
        val receiver: (EngineEvent) -> Unit = received::add
        dispatcher.attach(receiver)
        dispatcher.onEvent(event(1))
        dispatcher.attach(receiver)
        dispatcher.onEvent(event(2))
        drain()
        assertEquals(listOf(2L), received.map { it.sequence })
    }

    @Test fun `duplicate and reordered events never regress published state`() {
        dispatcher.attach(received::add)
        listOf(2L, 2L, 1L, 3L).forEach { dispatcher.onEvent(event(it)) }
        drain()
        assertEquals(listOf(2L, 3L), received.map { it.sequence })
    }

    @Test fun `reattachment accepts a new engine sequence and drops queued old engine events`() {
        dispatcher.attach(received::add)
        dispatcher.onEvent(event(100))
        drain()
        dispatcher.onEvent(event(101))
        dispatcher.detach()
        dispatcher.attach(received::add)
        dispatcher.onEvent(event(1))
        dispatcher.onEvent(event(1))
        dispatcher.onEvent(event(2))
        drain()
        assertEquals(listOf(100L, 1L, 2L), received.map { it.sequence })
        assertTrue(invalid.isEmpty())
    }

    @Test fun `unknown kinds consume their sequence without delivery or invalid diagnostics`() {
        dispatcher.attach(received::add)
        dispatcher.onEvent(event(1))
        dispatcher.onEvent(event(3, "future_kind"))
        dispatcher.onEvent(event(2))
        dispatcher.onEvent(event(4, "notice"))
        drain()
        assertEquals(listOf(1L, 4L), received.map { it.sequence })
        assertTrue(invalid.isEmpty())
    }

    @Test fun `malformed or unsupported envelopes do not poison subsequent deliveries`() {
        dispatcher.attach(received::add)
        listOf(null, "not JSON", "[]", event(1).replace("\"version\":1", "\"version\":2"),
            event(0), event(1, ""), event(1).replace("{\"Status\":\"connecting\"}", "null"),
        ).forEach(dispatcher::onEvent)
        dispatcher.onEvent(event(1))
        drain()
        assertEquals(7, invalid.size)
        assertEquals(listOf(1L), received.map { it.sequence })
    }

    @Test fun `unknown kinds still require a valid version sequence and payload`() {
        dispatcher.attach(received::add)
        listOf(event(0, "future_kind"),
            event(1, "future_kind").replace("\"version\":1", "\"version\":2"),
            event(1, "future_kind").replace("{\"Status\":\"connecting\"}", "null"),
            event(1).replace("\"kind\":\"state\"", "\"kind\":123"),
        ).forEach(dispatcher::onEvent)
        drain()
        assertEquals(4, invalid.size)
        assertTrue(received.isEmpty())
    }

    @Test fun `no detached owner's malformed event escapes into a new owner's diagnostics`() {
        dispatcher.attach(received::add)
        dispatcher.onEvent("bad old event")
        dispatcher.detach()
        drain()
        assertTrue(invalid.isEmpty())
    }
}
