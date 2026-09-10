package com.openrung.net

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class ProbeResourceTest {
    @Test fun `cancel closes socket and joins blocked worker before caller returns`() = runBlocking {
        val entered = CountDownLatch(1)
        val exited = AtomicBoolean(false)
        lateinit var socket: DatagramSocket
        val task = launch(Dispatchers.Default) {
            withProbeResource({ DatagramSocket().also { socket = it } }, DatagramSocket::close) { s ->
                try { entered.countDown(); s.receive(DatagramPacket(ByteArray(64), 64)) }
                finally { exited.set(true) }
            }
        }
        assertTrue(entered.await(2, TimeUnit.SECONDS))
        withTimeout(2000) { task.cancelAndJoin() }
        assertTrue(socket.isClosed)
        assertTrue(exited.get())
    }

    @Test fun `success and exception both release the probe resource`() = runBlocking {
        var closes = 0
        assertEquals(42, withProbeResource({ 42 }, { closes++ }) { it })
        try { withProbeResource({ 1 }, { closes++ }) { error("failed exchange") }; fail() }
        catch (_: IllegalStateException) { }
        assertEquals(2, closes)
    }
}
