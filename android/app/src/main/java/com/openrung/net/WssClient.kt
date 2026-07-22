package com.openrung.net

import android.net.VpnService
import com.openrung.model.WssFrontDescriptor
import com.openrung.vpn.WssFrontSetValidator
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungWSSClient
import io.nekohasekai.libbox.OpenRungWSSListener
import io.nekohasekai.libbox.OpenRungWSSProtector
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.InetAddress
import kotlin.coroutines.coroutineContext

data class WssConnectResult(
    val succeeded: Boolean,
    val reason: String,
    val errorText: String,
    val bridgeHost: String,
    val bridgePort: Int,
)

/** A two-phase handle so disconnect can cancel a blocking native WSS handshake. */
interface WssSession {
    suspend fun connect(): WssConnectResult
    suspend fun awaitFailure(): String
    fun close()
}

/** Android application adapter around the transport-only gomobile wrapper. */
object WssClient {
    fun create(
        vpnService: VpnService,
        advertisedFrontUrl: String,
        opaqueTicket: String,
    ): WssSession {
        val protector = socketProtector(vpnService::protect)
        val failure = CompletableDeferred<String>()
        val listener = OpenRungWSSListener { reason ->
            failure.complete(reason.ifBlank { "WSS session stopped unexpectedly" })
        }
        // Both values pass straight through the Go wrapper to wsscore.DialClient. They are never
        // normalized, reconstructed, logged, or placed in a URL by this layer.
        val client = Libbox.newOpenRungWSSClient(
            advertisedFrontUrl,
            opaqueTicket,
            protector,
            listener,
        )
        return LibboxWssSession(client, failure)
    }

    /** The callback's boolean is returned exactly; wsscore fails closed before connect(2). */
    internal fun socketProtector(protect: (Int) -> Boolean): OpenRungWSSProtector =
        OpenRungWSSProtector { fd -> protect(fd) }
}

/**
 * Production signed-front validator. All canonical URL, ID, version, uniqueness, and ordering
 * rules stay in the pinned wsscore module; Kotlin accepts only the exact advertised set.
 */
object NativeWssFrontSetValidator : WssFrontSetValidator {
    private val json = Json { encodeDefaults = true }

    override fun normalize(fronts: List<WssFrontDescriptor>): List<WssFrontDescriptor> {
        val encoded = json.encodeToString(fronts)
        val accepted = try {
            Libbox.openRungValidateWSSFronts(encoded)
        } catch (error: LinkageError) {
            // A stale/unsupported native artifact is a local platform limitation. Present it to
            // policy as validation unavailability so the original direct result is retained and
            // no ticket is requested.
            throw IllegalStateException("native WSS front validator is unavailable", error)
        }
        check(accepted) { "invalid signed WSS front set" }
        return fronts.toList()
    }
}

private class LibboxWssSession(
    private val client: OpenRungWSSClient,
    private val failure: CompletableDeferred<String>,
) : WssSession {
    override suspend fun connect(): WssConnectResult = withContext(Dispatchers.IO) {
        val native = client.connect()
        val result = WssConnectResult(
            succeeded = native.succeeded(),
            reason = native.reason(),
            errorText = native.errorText(),
            bridgeHost = native.bridgeHost(),
            bridgePort = native.bridgePort(),
        )
        try {
            coroutineContext.ensureActive()
        } catch (cancellation: CancellationException) {
            client.close()
            throw cancellation
        }
        if (!result.succeeded) {
            client.close()
            return@withContext result
        }
        val address = runCatching { InetAddress.getByName(result.bridgeHost) }.getOrNull()
        if (address?.isLoopbackAddress != true || result.bridgePort !in 1..65_535) {
            client.close()
            return@withContext result.copy(
                succeeded = false,
                reason = "adapter",
                errorText = "WSS adapter returned no safe loopback endpoint",
            )
        }
        result
    }

    override suspend fun awaitFailure(): String = failure.await()

    override fun close() {
        client.close()
        failure.cancel()
    }
}
