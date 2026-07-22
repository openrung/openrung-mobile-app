package com.openrung.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

class WssClientTest {
    @Test
    fun `socket protector passes the exact fd and result through`() {
        var protectedFd = -1
        val protector = WssClient.socketProtector { fd ->
            protectedFd = fd
            fd == 47
        }

        assertTrue(protector.protect(47))
        assertEquals(47, protectedFd)
        assertFalse(protector.protect(48))
        assertEquals(48, protectedFd)
    }

    @Test
    fun `socket protector does not turn rejection into success`() {
        val protector = WssClient.socketProtector { false }

        assertFalse(protector.protect(9))
    }

    @Test
    fun `native close is dispatched once and completion waits for the blocking call`() {
        var scheduled: Runnable? = null
        val closes = AtomicInteger()
        val close = NativeWssCloseOnce(
            closeNative = { closes.incrementAndGet() },
            dispatch = { task ->
                check(scheduled == null)
                scheduled = task
            },
        )

        val first = close.close()
        val second = close.close()

        assertSame(first, second)
        assertEquals(0, closes.get())
        assertFalse(first.isCompleted)
        checkNotNull(scheduled).run()
        assertEquals(1, closes.get())
        assertTrue(first.isCompleted)
    }

    @Test
    fun `production native close dispatcher never runs inline on its caller`() {
        val caller = Thread.currentThread()
        val closeThread = AtomicReference<Thread>()
        val closed = CountDownLatch(1)
        val completion = NativeWssCloseOnce(
            closeNative = {
                closeThread.set(Thread.currentThread())
                closed.countDown()
            },
        ).close()

        assertTrue(closed.await(5, TimeUnit.SECONDS))
        assertTrue(completion.isCompleted)
        assertTrue(closeThread.get() !== caller)
    }
}
