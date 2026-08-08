package com.openrung.net

import com.openrung.vpn.isGenuineRemoteDataPathFailure
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import java.net.PortUnreachableException
import java.net.ProtocolException
import java.net.SocketTimeoutException

class TunnelPathProbeTest {
    @Test
    fun `dns failure wraps the cause and never reaches the http stage`() {
        val timeout = SocketTimeoutException("no DNS response through the tunnel")
        val http = RecordingHttpProbe()
        val probe = TunnelPathProbe(failingDnsProbe(timeout), http)

        val error = assertThrows(DnsPathUnverifiedException::class.java) {
            runBlocking { probe.verifyOnce() }
        }
        assertSame(timeout, error.cause)
        assertEquals("a failed DNS stage must skip the HTTPS stage", 0, http.calls)
    }

    @Test
    fun `passing dns stage returns the http result`() = runBlocking {
        val http = RecordingHttpProbe()
        val probe = TunnelPathProbe(respondingDnsProbe(), http)

        val result = probe.verify()
        assertEquals(ProbeTargets.TUNNEL_PROBE_URLS.first(), result.endpoint)
        assertEquals(1, http.calls)
    }

    @Test
    fun `http failure after healthy dns propagates untouched`() {
        val refused = SocketTimeoutException("probe endpoints unreachable through the tunnel")
        val probe = TunnelPathProbe(
            respondingDnsProbe(),
            object : TunnelHttpProbe {
                override suspend fun verify(): InternetProbeResult = throw refused
                override suspend fun verifyOnce(): InternetProbeResult = throw refused
            },
        )

        val error = assertThrows(SocketTimeoutException::class.java) {
            runBlocking { probe.verify() }
        }
        assertSame(refused, error)
    }

    @Test
    fun `cancellation is never converted into a dns-path failure`() {
        val probe = TunnelPathProbe(
            DnsProbe(transport = { throw CancellationException("scope stopped") }, elapsedRealtime = { 0L }),
            RecordingHttpProbe(),
        )
        assertThrows(CancellationException::class.java) {
            runBlocking { probe.verifyOnce() }
        }
    }

    @Test
    fun `dns failure is classified as genuine remote through the wrapper`() {
        // Asserted against the PRODUCTION allow-list, not a hand-rolled chain walk: the gate
        // must see through the wrapper, or a dead resolver could never unlock WSS fallback.
        listOf(
            SocketTimeoutException("timeout"),
            PortUnreachableException("no listener behind the tunnel"),
            ProtocolException("malformed answer"),
        ).forEach { cause ->
            val error = assertThrows(DnsPathUnverifiedException::class.java) {
                runBlocking {
                    TunnelPathProbe(failingDnsProbe(cause), RecordingHttpProbe()).verifyOnce()
                }
            }
            assertTrue(cause::class.java.simpleName, isGenuineRemoteDataPathFailure(error))
        }
    }

    @Test
    fun `a local dns-stage failure stays local through the wrapper`() {
        // The inverse guard: an unknown/local error must NOT be laundered into remote evidence
        // by the wrapper, or a broken device would unlock WSS fallback on every connect.
        val error = assertThrows(DnsPathUnverifiedException::class.java) {
            runBlocking {
                TunnelPathProbe(
                    failingDnsProbe(IllegalStateException("local platform failure")),
                    RecordingHttpProbe(),
                ).verifyOnce()
            }
        }
        assertFalse(isGenuineRemoteDataPathFailure(error))
    }

    private fun failingDnsProbe(cause: Throwable) = DnsProbe(
        transport = { throw cause },
        elapsedRealtime = { 0L },
    )

    private fun respondingDnsProbe() = DnsProbe(
        transport = { query ->
            byteArrayOf(query[0], query[1], 0x81.toByte(), 0x80.toByte(), 0, 0, 0, 0, 0, 0, 0, 0)
        },
        elapsedRealtime = { 0L },
    )

    private class RecordingHttpProbe : TunnelHttpProbe {
        var calls = 0
        override suspend fun verify(): InternetProbeResult {
            calls++
            return InternetProbeResult(ProbeTargets.TUNNEL_PROBE_URLS.first(), 42)
        }

        override suspend fun verifyOnce(): InternetProbeResult = verify()
    }
}
