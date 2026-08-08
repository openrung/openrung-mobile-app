package com.openrung.net

import com.openrung.vpn.isGenuineRemoteDataPathFailure
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.ProtocolException
import java.net.SocketTimeoutException

class DnsProbeTest {
    @Test
    fun `query encodes a well-formed recursion-desired A question`() {
        val query = DnsProbeMessage.encodeQuery(0xBEEF, "abc.probe.openrung.org")

        assertEquals(0xBE.toByte(), query[0])
        assertEquals(0xEF.toByte(), query[1])
        assertEquals(0x01.toByte(), query[2]) // RD
        assertEquals(0x00.toByte(), query[3])
        assertEquals(1, ((query[4].toInt() and 0xFF) shl 8) or (query[5].toInt() and 0xFF)) // QDCOUNT
        // QNAME: 3"abc" 5"probe" 8"openrung" 3"org" 0
        var offset = 12
        listOf("abc", "probe", "openrung", "org").forEach { label ->
            assertEquals(label.length, query[offset].toInt())
            assertEquals(label, String(query, offset + 1, label.length, Charsets.US_ASCII))
            offset += 1 + label.length
        }
        assertEquals(0, query[offset].toInt())
        // QTYPE A, QCLASS IN
        assertEquals(1, query[offset + 2].toInt())
        assertEquals(1, query[offset + 4].toInt())
        assertEquals(offset + 4, query.lastIndex)
    }

    @Test
    fun `any response with matching id counts including NXDOMAIN`() {
        // NXDOMAIN is expected until the wildcard probe record exists; the response arriving at
        // all is what proves the hijack -> DoH -> proxy path.
        val nxdomain = byteArrayOf(
            0xBE.toByte(), 0xEF.toByte(), // id
            0x81.toByte(), 0x83.toByte(), // QR + RD + RA + RCODE 3
            0, 0, 0, 0, 0, 0, 0, 0,
        )
        assertTrue(DnsProbeMessage.isResponseFor(nxdomain, 0xBEEF))
    }

    @Test
    fun `mismatched id truncated header or echoed query are rejected`() {
        val response = byteArrayOf(
            0xBE.toByte(), 0xEF.toByte(), 0x80.toByte(), 0x00, 0, 0, 0, 0, 0, 0, 0, 0,
        )
        assertFalse(DnsProbeMessage.isResponseFor(response, 0xBEEE))
        assertFalse(DnsProbeMessage.isResponseFor(response.copyOf(11), 0xBEEF))
        // QR clear = our own query bounced back; that proves nothing.
        val echo = DnsProbeMessage.encodeQuery(0xBEEF, "abc.probe.openrung.org")
        assertFalse(DnsProbeMessage.isResponseFor(echo, 0xBEEF))
    }

    @Test
    fun `probe accepts a matching response and reports the nonce qname`() = runBlocking {
        val queries = ArrayList<ByteArray>()
        val probe = DnsProbe(
            transport = { query ->
                queries.add(query)
                respondTo(query)
            },
            elapsedRealtime = { 0L },
        )

        val result = probe.verifyOnce()
        assertTrue(result.qname.endsWith(".${ProbeTargets.DNS_PROBE_QNAME_SUFFIX}"))
        val nonce = result.qname.removeSuffix(".${ProbeTargets.DNS_PROBE_QNAME_SUFFIX}")
        assertEquals(16, nonce.length)
        assertEquals(1, queries.size)
    }

    @Test
    fun `each attempt uses a fresh nonce so no cache can answer`() = runBlocking {
        val qnames = ArrayList<String>()
        val probe = DnsProbe(
            transport = { query ->
                qnames.add(decodeQname(query))
                respondTo(query)
            },
            elapsedRealtime = { 0L },
        )
        probe.verifyOnce()
        probe.verifyOnce()
        assertEquals(2, qnames.size)
        assertNotEquals(qnames[0], qnames[1])
    }

    @Test
    fun `verifyOnce propagates the transport timeout unwrapped`() {
        val probe = DnsProbe(
            transport = { throw SocketTimeoutException("no response through the tunnel") },
            elapsedRealtime = { 0L },
        )
        assertThrows(SocketTimeoutException::class.java) {
            runBlocking { probe.verifyOnce() }
        }
    }

    @Test
    fun `verify keeps the last error as cause after the deadline`() {
        var now = 0L
        val probe = DnsProbe(
            transport = {
                now += 3_000
                throw SocketTimeoutException("no response through the tunnel")
            },
            elapsedRealtime = { now },
        )
        val error = assertThrows(IOException::class.java) {
            runBlocking { probe.verify() }
        }
        assertTrue(error.cause is SocketTimeoutException)
    }

    @Test
    fun `mismatched response fails the attempt rather than passing silently`() {
        val probe = DnsProbe(
            transport = { ByteArray(12) },
            elapsedRealtime = { 0L },
        )
        val error = assertThrows(ProtocolException::class.java) {
            runBlocking { probe.verifyOnce() }
        }
        // Must classify REMOTE (matching iOS's URLError(.cannotParseResponse)): a garbled
        // in-tunnel answer is evidence about the path, and a bare IOException would fail local
        // and abort the whole relay ladder instead of falling back.
        assertTrue(isGenuineRemoteDataPathFailure(DnsPathUnverifiedException(error)))
    }

    private fun respondTo(query: ByteArray): ByteArray = byteArrayOf(
        query[0], query[1],
        0x81.toByte(), 0x83.toByte(),
        0, 0, 0, 0, 0, 0, 0, 0,
    )

    private fun decodeQname(query: ByteArray): String {
        val labels = ArrayList<String>()
        var offset = 12
        while (query[offset].toInt() != 0) {
            val length = query[offset].toInt()
            labels.add(String(query, offset + 1, length, Charsets.US_ASCII))
            offset += 1 + length
        }
        return labels.joinToString(".")
    }
}
