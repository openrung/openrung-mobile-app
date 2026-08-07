package com.openrung.net

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.UnknownHostException

class InternetProbeTest {
    @Test
    fun `defaults use only dedicated forced-proxy hostname`() {
        assertEquals(
            listOf("https://cp.cloudflare.com/generate_204"),
            InternetProbe.ENDPOINTS,
        )
        assertTrue(InternetProbe.ENDPOINTS.single().contains(SingBoxConfiguration.CONNECTIVITY_PROBE_HOST))
        assertFalse(InternetProbe.ENDPOINTS.single().contains("www.gstatic.com"))
    }

    @Test
    fun `probe requires fresh DNS before HTTPS`() = runTest {
        val calls = mutableListOf<String>()

        runFreshDnsHttpsProbe(
            resolveFreshDns = { calls += "dns" },
            probeHttps = { calls += "https" },
        )

        assertEquals(listOf("dns", "https"), calls)
    }

    @Test
    fun `fresh DNS failure cannot be masked by reachable HTTPS`() = runTest {
        var httpsAttempted = false

        val failure = runCatching {
            runFreshDnsHttpsProbe(
                resolveFreshDns = { throw UnknownHostException("proxied DoH failed") },
                probeHttps = { httpsAttempted = true },
            )
        }.exceptionOrNull()

        assertTrue(failure is UnknownHostException)
        assertFalse(httpsAttempted)
    }

    @Test
    fun `only successful HTTPS statuses pass`() {
        assertFalse(InternetProbe.acceptsHttpStatus(199))
        assertTrue(InternetProbe.acceptsHttpStatus(200))
        assertTrue(InternetProbe.acceptsHttpStatus(204))
        assertTrue(InternetProbe.acceptsHttpStatus(299))
        assertFalse(InternetProbe.acceptsHttpStatus(300))
        assertFalse(InternetProbe.acceptsHttpStatus(503))
    }

    @Test
    fun `legacy fresh DNS query is an uncached wire A lookup`() {
        val query = TunnelDnsAProbe.makeQuery("cp.cloudflare.com", 0x1234)

        assertEquals(0x12, query[0].toInt() and 0xff)
        assertEquals(0x34, query[1].toInt() and 0xff)
        assertEquals(0x01, query[2].toInt() and 0xff) // Recursion desired.
        assertEquals(1, unsignedShort(query, 4))
        assertTrue(query.takeLast(4).toByteArray().contentEquals(byteArrayOf(0, 1, 0, 1)))
    }

    @Test
    fun `legacy fresh DNS accepts a matching address answer`() {
        val response = successfulDnsResponse(transactionId = 0x2345, includeAddress = true)

        TunnelDnsAProbe.validateResponse(response, transactionId = 0x2345)
    }

    @Test
    fun `legacy fresh DNS rejects empty and failed replies`() {
        val empty = successfulDnsResponse(transactionId = 0x3456, includeAddress = false)
        val servfail = empty.copyOf().apply { this[3] = 0x82.toByte() }

        assertTrue(
            runCatching {
                TunnelDnsAProbe.validateResponse(empty, transactionId = 0x3456)
            }.exceptionOrNull() != null,
        )
        assertTrue(
            runCatching {
                TunnelDnsAProbe.validateResponse(servfail, transactionId = 0x3456)
            }.exceptionOrNull() != null,
        )
    }

    @Test
    fun `legacy fresh DNS rejects mismatched and truncated replies`() {
        val response = successfulDnsResponse(transactionId = 0x4567, includeAddress = true)
        val truncated = response.copyOf().apply { this[2] = (this[2].toInt() or 0x02).toByte() }

        assertTrue(
            runCatching {
                TunnelDnsAProbe.validateResponse(response, transactionId = 0x4568)
            }.exceptionOrNull() != null,
        )
        assertTrue(
            runCatching {
                TunnelDnsAProbe.validateResponse(truncated, transactionId = 0x4567)
            }.exceptionOrNull() != null,
        )
    }

    private fun successfulDnsResponse(transactionId: Int, includeAddress: Boolean): ByteArray {
        val query = TunnelDnsAProbe.makeQuery("cp.cloudflare.com", transactionId)
        val responseHeaderAndQuestion = query.copyOf().apply {
            this[2] = 0x81.toByte()
            this[3] = 0x80.toByte()
            this[6] = 0
            this[7] = if (includeAddress) 1 else 0
        }
        if (!includeAddress) return responseHeaderAndQuestion
        return responseHeaderAndQuestion + byteArrayOf(
            0xc0.toByte(), 0x0c, // Answer name points at the question.
            0x00, 0x01, // A.
            0x00, 0x01, // IN.
            0x00, 0x00, 0x00, 0x3c, // TTL.
            0x00, 0x04,
            104, 16, 123, 96,
        )
    }

    private fun unsignedShort(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xff) shl 8) or
            (bytes[offset + 1].toInt() and 0xff)
}
