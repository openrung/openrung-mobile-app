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
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.EmptyCoroutineContext
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

    /** Starts an idempotent native close off Main and exposes completion for ordered recovery. */
    fun close(): Deferred<Unit>
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
    private val nativeClose = NativeWssCloseOnce(client::close)

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
            nativeClose.close()
            throw cancellation
        }
        if (!result.succeeded) {
            nativeClose.close()
            return@withContext result
        }
        val address = runCatching { InetAddress.getByName(result.bridgeHost) }.getOrNull()
        if (address?.isLoopbackAddress != true || result.bridgePort !in 1..65_535) {
            nativeClose.close()
            return@withContext result.copy(
                succeeded = false,
                reason = "adapter",
                errorText = "WSS adapter returned no safe loopback endpoint",
            )
        }
        result
    }

    override suspend fun awaitFailure(): String = failure.await()

    override fun close(): Deferred<Unit> {
        failure.cancel()
        return nativeClose.close()
    }
}

/**
 * Native Close can wait for goroutines and socket shutdown. Dispatch it directly to IO so even a
 * synchronous VpnService lifecycle callback can begin teardown without running or blocking on the
 * Android main thread. The returned Deferred lets recovery await full adapter retirement before it
 * reconnects, and the CAS keeps concurrent lifecycle/handshake closes strictly one-shot.
 */
internal class NativeWssCloseOnce(
    private val closeNative: () -> Unit,
    private val dispatch: (Runnable) -> Unit = { task ->
        Dispatchers.IO.dispatch(EmptyCoroutineContext, task)
    },
) {
    private val started = AtomicBoolean(false)
    private val completion = CompletableDeferred<Unit>()

    fun close(): Deferred<Unit> {
        if (started.compareAndSet(false, true)) {
            val task = Runnable {
                try {
                    closeNative()
                    completion.complete(Unit)
                } catch (error: Throwable) {
                    completion.completeExceptionally(error)
                }
            }
            try {
                dispatch(task)
            } catch (error: Throwable) {
                completion.completeExceptionally(error)
            }
        }
        return completion
    }
}
