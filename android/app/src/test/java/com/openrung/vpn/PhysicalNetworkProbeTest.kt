package com.openrung.vpn

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class PhysicalNetworkProbeTest {
    @Test
    fun `physical probe uses only independent connectivity endpoints`() {
        assertEquals(
            listOf(
                "https://www.gstatic.com/generate_204",
                "https://cp.cloudflare.com/generate_204",
            ),
            PhysicalNetworkProbe.ENDPOINTS,
        )
        assertTrue(
            PhysicalNetworkProbe.ENDPOINTS.none { endpoint ->
                endpoint.contains("openrung", ignoreCase = true) ||
                    endpoint.contains("broker", ignoreCase = true)
            },
        )
    }

    @Test
    fun `any HTTP response proves connectivity with bounded headerless settings`() = runBlocking {
        val connection = FakeHttpURLConnection(responseStatus = 503)

        val reachable = PhysicalNetworkProbe.isReachable(
            openConnection = { connection },
            ioDispatcher = Dispatchers.Unconfined,
        )

        assertTrue(reachable)
        assertEquals("HEAD", connection.requestMethod)
        assertEquals(3_000, connection.connectTimeout)
        assertEquals(3_000, connection.readTimeout)
        assertFalse(connection.instanceFollowRedirects)
        assertFalse(connection.useCaches)
        assertTrue(connection.requestProperties.isEmpty())
        assertTrue(connection.disconnected)
    }

    @Test
    fun `connection and response errors report unreachable and always disconnect`() = runBlocking {
        val responseFailure = FakeHttpURLConnection(responseFailure = IOException("offline"))

        assertFalse(
            PhysicalNetworkProbe.isReachable(
                openConnection = { responseFailure },
                ioDispatcher = Dispatchers.Unconfined,
            ),
        )
        assertTrue(responseFailure.disconnected)

        assertFalse(
            PhysicalNetworkProbe.isReachable(
                openConnection = { throw IOException("cannot open") },
                ioDispatcher = Dispatchers.Unconfined,
            ),
        )
    }

    @Test
    fun `coroutine cancellation is never converted to an offline result`() {
        val cancellation = CancellationException("disconnect")
        val connection = FakeHttpURLConnection(responseFailure = cancellation)

        val observed = try {
            runBlocking {
                PhysicalNetworkProbe.isReachable(
                    openConnection = { connection },
                    ioDispatcher = Dispatchers.Unconfined,
                )
            }
            throw AssertionError("expected cancellation")
        } catch (error: CancellationException) {
            error
        }

        assertSame(cancellation, observed)
        assertTrue(connection.disconnected)
    }

    @Test
    fun `cancellation landing during a response cannot become reachable`() = runBlocking {
        val responseStarted = CountDownLatch(1)
        val allowResponse = CountDownLatch(1)
        val connection = FakeHttpURLConnection(
            responseBlock = {
                responseStarted.countDown()
                assertTrue(allowResponse.await(2, TimeUnit.SECONDS))
                204
            },
        )
        val probe = async(Dispatchers.Default) {
            PhysicalNetworkProbe.isReachable(
                openConnection = { connection },
                ioDispatcher = Dispatchers.IO,
            )
        }

        assertTrue(responseStarted.await(2, TimeUnit.SECONDS))
        probe.cancel(CancellationException("network changed"))
        allowResponse.countDown()
        val observed = try {
            probe.await()
            throw AssertionError("expected cancellation")
        } catch (error: CancellationException) {
            error
        }

        assertEquals("network changed", observed.message)
        assertTrue(connection.disconnected)
    }
}

private class FakeHttpURLConnection(
    private val responseStatus: Int = 204,
    private val responseFailure: Throwable? = null,
    private val responseBlock: (() -> Int)? = null,
) : HttpURLConnection(URL("https://connectivity.example/generate_204")) {
    var disconnected = false

    override fun getResponseCode(): Int {
        responseFailure?.let { throw it }
        return responseBlock?.invoke() ?: responseStatus
    }

    override fun disconnect() {
        disconnected = true
    }

    override fun usingProxy(): Boolean = false

    override fun connect() = Unit
}
