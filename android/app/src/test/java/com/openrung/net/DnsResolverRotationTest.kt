package com.openrung.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DnsResolverRotationTest {
    @Test
    fun `starts with the default resolver order`() {
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), DnsResolverRotation().currentServers())
    }

    @Test
    fun `a failure of the current order advances exactly once`() {
        val rotation = DnsResolverRotation()
        val failed = rotation.currentServers()

        assertTrue(rotation.noteDnsPathFailure(failed))
        assertEquals(listOf("8.8.8.8", "1.1.1.1"), rotation.currentServers())

        // A duplicate report of the already-rotated-away order must not advance again —
        // otherwise a startup race plus the health loop could skip an untried resolver.
        assertFalse(rotation.noteDnsPathFailure(failed))
        assertEquals(listOf("8.8.8.8", "1.1.1.1"), rotation.currentServers())
    }

    @Test
    fun `rotation wraps around the resolver list`() {
        val rotation = DnsResolverRotation()
        assertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))
        assertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))
        assertEquals(listOf("1.1.1.1", "8.8.8.8"), rotation.currentServers())
    }

    @Test
    fun `custom resolver lists rotate the same way`() {
        val rotation = DnsResolverRotation(listOf("a", "b", "c"))
        assertTrue(rotation.noteDnsPathFailure(listOf("a", "b", "c")))
        assertEquals(listOf("b", "c", "a"), rotation.currentServers())
        assertTrue(rotation.noteDnsPathFailure(listOf("b", "c", "a")))
        assertEquals(listOf("c", "a", "b"), rotation.currentServers())
    }
}
