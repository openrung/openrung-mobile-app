package com.openrung.bridge

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.openrung.net.BrokerNativeFailure
import com.openrung.net.BrokerNativeFailureKind
import com.openrung.net.NativeBrokerOperationFactory
import com.openrung.net.ReactNativeBrokerTransport
import com.openrung.net.requireNativeBrokerSuccess
import com.openrung.net.runNativeBrokerOperation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * Dedicated classic NativeModule for eligible React Native broker traffic.
 *
 * WSS tickets deliberately remain absent: Android's VpnService is their only owner.
 */
class OpenRungBrokerModule(
    reactContext: ReactApplicationContext,
) : ReactContextBaseJavaModule(reactContext) {
    private val requests = OpenRungBrokerRequestCoordinator()

    override fun getName(): String = NAME

    override fun invalidate() {
        requests.invalidate()
        super.invalidate()
    }

    @ReactMethod
    fun firstReachable(
        requestId: String,
        primary: String,
        limit: Double,
        clientId: String,
        sessionId: String,
        promise: Promise,
    ) {
        val validatedLimit = limit.toRelayLimitOrNull()
        if (validatedLimit == null) {
            promise.rejectBridge(
                BrokerBridgeFailure.validation("native broker relay limit must be a positive integer"),
            )
            return
        }
        requests.firstReachable(
            requestId = requestId,
            primary = primary,
            limit = validatedLimit,
            clientId = clientId,
            sessionId = sessionId,
            callbacks = promise.callbacks(),
        )
    }

    @ReactMethod
    fun runSpeedTest(requestId: String, brokerUrl: String, promise: Promise) {
        requests.runSpeedTest(requestId, brokerUrl, promise.callbacks())
    }

    @ReactMethod
    fun sendTelemetryBatchJSON(
        requestId: String,
        brokerUrl: String,
        batchJson: String,
        promise: Promise,
    ) {
        requests.sendTelemetryBatchJSON(requestId, brokerUrl, batchJson, promise.callbacks())
    }

    @ReactMethod
    fun fetchManifestCandidate(requestId: String, candidateUrl: String, promise: Promise) {
        requests.fetchManifestCandidate(requestId, candidateUrl, promise.callbacks())
    }

    @ReactMethod
    fun cancel(requestId: String, promise: Promise) {
        promise.resolve(requests.cancel(requestId))
    }

    private fun Promise.callbacks(): BrokerRequestCallbacks =
        BrokerRequestCallbacks(
            resolve = { result -> resolve(Arguments.makeNativeMap(result)) },
            reject = { failure -> rejectBridge(failure) },
        )

    private fun Promise.rejectBridge(failure: BrokerBridgeFailure) {
        val userInfo = buildMap<String, Any> {
            put("kind", failure.kind.value)
            failure.httpStatus?.let { put("httpStatus", it) }
            failure.retryAfterMillis?.let { put("retryAfterMillis", it.toDouble()) }
        }
        reject(
            failure.kind.value,
            failure.message,
            Arguments.makeNativeMap(userInfo),
        )
    }

    private fun Double.toRelayLimitOrNull(): Int? {
        if (!isFinite() || this < 1.0 || this > Int.MAX_VALUE.toDouble()) return null
        val converted = toInt()
        return converted.takeIf { it.toDouble() == this }
    }

    companion object {
        const val NAME = "OpenRungBroker"
    }
}

internal data class BrokerBridgeFailure(
    val kind: BrokerNativeFailureKind,
    val message: String,
    val httpStatus: Int? = null,
    val retryAfterMillis: Long? = null,
) {
    companion object {
        fun cancelled(): BrokerBridgeFailure =
            BrokerBridgeFailure(
                kind = BrokerNativeFailureKind.CANCELLED,
                message = "native broker request was cancelled",
            )

        fun validation(message: String): BrokerBridgeFailure =
            BrokerBridgeFailure(
                kind = BrokerNativeFailureKind.VALIDATION,
                message = message,
            )

        fun unavailable(): BrokerBridgeFailure =
            BrokerBridgeFailure(
                kind = BrokerNativeFailureKind.UNAVAILABLE,
                message = "native broker transport is unavailable; rebuild the app",
            )

        fun unknown(): BrokerBridgeFailure =
            BrokerBridgeFailure(
                kind = BrokerNativeFailureKind.UNKNOWN,
                message = "native broker request failed",
            )

        fun from(error: Throwable): BrokerBridgeFailure = when (error) {
            is CancellationException -> cancelled()
            is BrokerNativeFailure -> {
                if (error.kind == BrokerNativeFailureKind.UNAVAILABLE) {
                    unavailable()
                } else {
                    BrokerBridgeFailure(
                        kind = error.kind,
                        message = error.message ?: "native broker request failed",
                        httpStatus = error.httpStatus,
                        retryAfterMillis = error.retryAfterMillis,
                    )
                }
            }
            is LinkageError -> unavailable()
            else -> unknown()
        }
    }
}

internal data class BrokerRequestCallbacks(
    val resolve: (Map<String, Any>) -> Unit,
    val reject: (BrokerBridgeFailure) -> Unit,
)

/**
 * Thread-safe lifecycle owner for React Native broker requests.
 *
 * The registry owns Jobs, never gomobile objects. Cancelling a Job flows through PR 2's
 * [runNativeBrokerOperation], which concurrently calls Close on that request's single-use
 * operation. A synchronized terminal transition ensures cancellation and success cannot both be
 * delivered.
 */
internal class OpenRungBrokerRequestCoordinator(
    private val operationFactory: NativeBrokerOperationFactory =
        ReactNativeBrokerTransport.operationFactory,
    requestDispatcher: CoroutineDispatcher = Dispatchers.Default,
    private val nativeIoDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val lock = Any()
    private val scope = CoroutineScope(SupervisorJob() + requestDispatcher)
    private val active = LinkedHashMap<String, ActiveRequest>()
    private var invalidated = false

    fun firstReachable(
        requestId: String,
        primary: String,
        limit: Int,
        clientId: String,
        sessionId: String,
        callbacks: BrokerRequestCallbacks,
    ) {
        submit(requestId, callbacks) {
            val native = runNativeBrokerOperation(operationFactory, nativeIoDispatcher) { operation ->
                operation.firstReachable(primary, limit, clientId, sessionId)
            }
            val result = requireNativeBrokerSuccess(native, "native broker discovery")
            val projectedRelayJson = projectRelayJsonForReactNative(result.relayJson)
            mapOf(
                "brokerUrl" to result.brokerUrl,
                "relayJson" to projectedRelayJson,
                "keyId" to result.keyId,
                "signatureVerified" to result.signatureVerified,
            )
        }
    }

    fun runSpeedTest(
        requestId: String,
        brokerUrl: String,
        callbacks: BrokerRequestCallbacks,
    ) {
        submit(requestId, callbacks) {
            val native = runNativeBrokerOperation(operationFactory, nativeIoDispatcher) { operation ->
                operation.runSpeedTest(brokerUrl)
            }
            val result = requireNativeBrokerSuccess(native, "native broker speed test")
            mapOf(
                "bytes" to result.bytes.toDouble(),
                "ttfbMillis" to result.ttfbMillis.toDouble(),
                "downloadDurationMillis" to result.downloadDurationMillis.toDouble(),
                "totalDurationMillis" to result.totalDurationMillis.toDouble(),
                "mbps" to result.mbps,
            )
        }
    }

    fun sendTelemetryBatchJSON(
        requestId: String,
        brokerUrl: String,
        batchJson: String,
        callbacks: BrokerRequestCallbacks,
    ) {
        submit(requestId, callbacks) {
            val native = runNativeBrokerOperation(operationFactory, nativeIoDispatcher) { operation ->
                operation.sendTelemetryBatchJSON(brokerUrl, batchJson)
            }
            requireNativeBrokerSuccess(native, "native telemetry upload")
            emptyMap()
        }
    }

    fun fetchManifestCandidate(
        requestId: String,
        candidateUrl: String,
        callbacks: BrokerRequestCallbacks,
    ) {
        submit(requestId, callbacks) {
            val native = runNativeBrokerOperation(operationFactory, nativeIoDispatcher) { operation ->
                operation.fetchManifestCandidate(candidateUrl)
            }
            val result = requireNativeBrokerSuccess(native, "native manifest fetch")
            mapOf(
                "bodyJson" to result.bodyJson,
                "sourceUrl" to result.sourceUrl,
            )
        }
    }

    /**
     * Idempotently requests cancellation and reports whether this call found an active request.
     * Registry removal is deferred until the cancelled Job finishes closing its native operation.
     */
    fun cancel(requestId: String): Boolean {
        val job = synchronized(lock) {
            val request = active[requestId] ?: return false
            if (request.state != RequestState.ACTIVE) return false
            request.state = RequestState.CANCELLING
            request.job
        }
        job.cancel(CancellationException("React Native broker request cancelled"))
        return true
    }

    fun invalidate() {
        val requests = synchronized(lock) {
            if (invalidated) return
            invalidated = true
            active.values.onEach { request ->
                if (request.state == RequestState.ACTIVE) {
                    request.state = RequestState.CANCELLING
                }
            }.toList()
        }
        requests.forEach { request ->
            request.job.cancel(CancellationException("OpenRungBroker module invalidated"))
        }
        scope.cancel(CancellationException("OpenRungBroker module invalidated"))
    }

    internal fun activeRequestCount(): Int = synchronized(lock) { active.size }

    private fun submit(
        requestId: String,
        callbacks: BrokerRequestCallbacks,
        block: suspend () -> Map<String, Any>,
    ) {
        if (requestId.isBlank()) {
            safelyReject(callbacks, BrokerBridgeFailure.validation("native broker request ID is required"))
            return
        }

        lateinit var request: ActiveRequest
        val job = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val result = block()
                currentCoroutineContext().ensureActive()
                completeSuccess(request, result)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                completeFailure(request, BrokerBridgeFailure.from(error))
            }
        }
        request = ActiveRequest(requestId, job, callbacks)

        val immediateFailure = synchronized(lock) {
            when {
                invalidated -> BrokerBridgeFailure.unavailable()
                active.containsKey(requestId) ->
                    BrokerBridgeFailure.validation("native broker request ID is already active")
                else -> {
                    active[requestId] = request
                    null
                }
            }
        }
        if (immediateFailure != null) {
            job.cancel()
            safelyReject(callbacks, immediateFailure)
            return
        }

        job.invokeOnCompletion { cause ->
            val failure = when (cause) {
                is CancellationException -> BrokerBridgeFailure.cancelled()
                null -> BrokerBridgeFailure.unknown()
                else -> BrokerBridgeFailure.from(cause)
            }
            completeFailure(request, failure)
        }
        job.start()
    }

    private fun completeSuccess(request: ActiveRequest, result: Map<String, Any>) {
        val callbacks = synchronized(lock) {
            if (request.state != RequestState.ACTIVE || active[request.requestId] !== request) {
                return
            }
            request.state = RequestState.TERMINAL
            active.remove(request.requestId)
            request.callbacks
        }
        runCatching { callbacks.resolve(result) }
    }

    private fun completeFailure(request: ActiveRequest, failure: BrokerBridgeFailure) {
        val terminal = synchronized(lock) {
            if (request.state == RequestState.TERMINAL || active[request.requestId] !== request) {
                return
            }
            val deliveredFailure =
                if (request.state == RequestState.CANCELLING) {
                    BrokerBridgeFailure.cancelled()
                } else {
                    failure
                }
            request.state = RequestState.TERMINAL
            active.remove(request.requestId)
            request.callbacks to deliveredFailure
        }
        safelyReject(terminal.first, terminal.second)
    }

    private fun safelyReject(callbacks: BrokerRequestCallbacks, failure: BrokerBridgeFailure) {
        runCatching { callbacks.reject(failure) }
    }

    private data class ActiveRequest(
        val requestId: String,
        val job: Job,
        val callbacks: BrokerRequestCallbacks,
        var state: RequestState = RequestState.ACTIVE,
    )

    private enum class RequestState {
        ACTIVE,
        CANCELLING,
        TERMINAL,
    }
}

/**
 * Removes PacketTunnel/VpnService-only WSS front metadata from the verified relay snapshot before
 * it crosses the React Native bridge. Generic JSON projection preserves forward-compatible
 * directory fields without teaching the bridge the relay schema.
 */
private fun projectRelayJsonForReactNative(relayJson: String): String {
    val root = try {
        Json.parseToJsonElement(relayJson) as? JsonObject
    } catch (cancellation: CancellationException) {
        throw cancellation
    } catch (_: SerializationException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    } ?: throw relayProjectionDecodeFailure()

    val relays = root["relays"] as? JsonArray ?: throw relayProjectionDecodeFailure()
    val projectedRelays = JsonArray(
        relays.map { relayElement ->
            val relay = relayElement as? JsonObject ?: throw relayProjectionDecodeFailure()
            JsonObject(relay.filterKeys { field -> field != WSS_FRONTS_FIELD })
        },
    )
    return JsonObject(
        root.toMutableMap().apply {
            put("relays", projectedRelays)
        },
    ).toString()
}

private fun relayProjectionDecodeFailure(): BrokerNativeFailure =
    BrokerNativeFailure(
        kind = BrokerNativeFailureKind.DECODE,
        message = "native broker relay directory could not be projected",
    )

private const val WSS_FRONTS_FIELD = "wss_fronts"
