package com.openrung.vpn

import com.openrung.net.InternetProbeHttpStatusException
import java.io.IOException
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLHandshakeException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteDataPathFailureTest {
    @Test
    fun `only positive remote network and protocol failures are eligible`() {
        val remote = listOf(
            SocketTimeoutException("timed out"),
            UnknownHostException("relay.example"),
            ConnectException("connection refused"),
            SSLHandshakeException("remote certificate rejected"),
            InternetProbeHttpStatusException(503),
            IOException("outer", ConnectException("reset")),
        )
        remote.forEach { assertTrue(it.toString(), isGenuineRemoteDataPathFailure(it)) }

        val localOrAmbiguous = listOf(
            IOException("VPN network is unavailable"),
            SecurityException("VPN permission revoked"),
            IllegalStateException("platform engine is unavailable"),
            IOException("generic local I/O failure"),
        )
        localOrAmbiguous.forEach { assertFalse(it.toString(), isGenuineRemoteDataPathFailure(it)) }
    }
}
