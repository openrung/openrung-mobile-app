package com.openrung.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

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
}
