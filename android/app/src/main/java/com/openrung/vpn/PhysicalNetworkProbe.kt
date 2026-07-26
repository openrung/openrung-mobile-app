package com.openrung.vpn

import android.net.Network
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

/**
 * Explicit ordinary-TLS exception used only to prove a selected non-VPN Android Network is alive.
 *
 * Brokerapi cannot preserve [Network.openConnection] routing, so this probe intentionally uses
 * independent connectivity endpoints and never sends OpenRung identity or broker headers.
 */
internal object PhysicalNetworkProbe {
    val ENDPOINTS: List<String> = listOf(
        "https://www.gstatic.com/generate_204",
        "https://cp.cloudflare.com/generate_204",
    )

    suspend fun isReachable(network: Network, endpoint: String): Boolean =
        isReachable(
            openConnection = {
                network.openConnection(URL(endpoint)) as HttpURLConnection
            },
        )

    /** Injectable connection seam keeps response/error behavior hostless and deterministic. */
    internal suspend fun isReachable(
        openConnection: () -> HttpURLConnection,
        ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    ): Boolean = withContext(ioDispatcher) {
        currentCoroutineContext().ensureActive()
        val connection = try {
            openConnection()
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Throwable) {
            return@withContext false
        }
        try {
            connection.requestMethod = "HEAD"
            connection.connectTimeout = REQUEST_TIMEOUT_MS
            connection.readTimeout = REQUEST_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            // Any received HTTP status proves this exact physical path can reach the internet.
            val responseReceived = connection.responseCode > 0
            currentCoroutineContext().ensureActive()
            responseReceived
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Throwable) {
            false
        } finally {
            connection.disconnect()
        }
    }

    private const val REQUEST_TIMEOUT_MS = 3_000
}
