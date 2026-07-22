package com.openrung.vpn

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class StopSafeResourceRegistryTest {
    @Test
    fun `resource published after stop is closed immediately and exactly once`() {
        val closes = AtomicInteger()
        val registry = StopSafeResourceRegistry(listOf("resource"))

        assertTrue(registry.stop())
        assertFalse(registry.replace("resource") { closes.incrementAndGet() })
        assertFalse(registry.stop())

        assertEquals(1, closes.get())
    }

    @Test
    fun `intentional stop wins first-stop arbitration and uses teardown order`() {
        val order = mutableListOf<String>()
        val registry = StopSafeResourceRegistry(listOf("status", "server", "tun"))
        registry.replace("tun") { order += "tun" }
        registry.replace("server") { order += "server" }
        registry.replace("status") { order += "status" }

        var unexpectedSignals = 0
        assertTrue(registry.stop())
        assertFalse(registry.stop { unexpectedSignals++ })

        assertEquals(0, unexpectedSignals)
        assertEquals(listOf("status", "server", "tun"), order)
    }

    @Test
    fun `unexpected-stop callback observes all engine resources already closed`() {
        val order = mutableListOf<String>()
        val registry = StopSafeResourceRegistry(listOf("engine"))
        registry.replace("engine") { order += "engine_closed" }

        registry.stop { order += "unexpected_published" }

        assertEquals(listOf("engine_closed", "unexpected_published"), order)
    }

    @Test
    fun `concurrent stop waits for the winning engine teardown`() {
        val closeStarted = CountDownLatch(1)
        val allowClose = CountDownLatch(1)
        val secondReturned = CountDownLatch(1)
        val registry = StopSafeResourceRegistry(listOf("engine"))
        registry.replace("engine") {
            closeStarted.countDown()
            allowClose.await()
        }

        val first = Thread { registry.stop() }.apply { start() }
        assertTrue(closeStarted.await(5, TimeUnit.SECONDS))
        val second = Thread {
            registry.stop()
            secondReturned.countDown()
        }.apply { start() }

        try {
            assertFalse(secondReturned.await(100, TimeUnit.MILLISECONDS))
        } finally {
            allowClose.countDown()
        }
        first.join(5_000)
        second.join(5_000)
        assertFalse(first.isAlive)
        assertFalse(second.isAlive)
        assertTrue(secondReturned.await(0, TimeUnit.MILLISECONDS))
    }

    @Test
    fun `concurrent publication and stop never leak or double-close a resource`() {
        repeat(250) {
            val closes = AtomicInteger()
            val registry = StopSafeResourceRegistry(listOf("resource"))
            val ready = CountDownLatch(2)
            val go = CountDownLatch(1)
            val done = CountDownLatch(2)

            Thread {
                ready.countDown()
                go.await()
                registry.replace("resource") { closes.incrementAndGet() }
                done.countDown()
            }.start()
            Thread {
                ready.countDown()
                go.await()
                registry.stop()
                done.countDown()
            }.start()

            assertTrue(ready.await(5, TimeUnit.SECONDS))
            go.countDown()
            assertTrue(done.await(5, TimeUnit.SECONDS))
            registry.stop()
            assertEquals("iteration $it", 1, closes.get())
        }
    }
}
