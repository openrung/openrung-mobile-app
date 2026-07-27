package com.openrung.net

import android.os.Build
import com.openrung.BuildConfig
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OpenRungBrokerManifestResult
import io.nekohasekai.libbox.OpenRungBrokerOperation
import io.nekohasekai.libbox.OpenRungBrokerRelayResult
import io.nekohasekai.libbox.OpenRungBrokerResult
import io.nekohasekai.libbox.OpenRungBrokerSpeedTestResult
import io.nekohasekai.libbox.OpenRungBrokerWSSTicketResult
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.IOException

/**
 * Bounded error kinds exposed to Android policy. The first ten values are the exact brokerapi
 * binding contract; [UNAVAILABLE] and [DECODE] describe failures introduced by this adapter.
 */
enum class BrokerNativeFailureKind(val value: String) {
    CANCELLED("cancelled"),
    TIMEOUT("timeout"),
    RATE_LIMITED("rate_limited"),
    HTTP_STATUS("http_status"),
    DNS("dns"),
    TLS("tls"),
    NETWORK("network"),
    VERIFICATION("verification"),
    VALIDATION("validation"),
    UNKNOWN("unknown"),
    UNAVAILABLE("unavailable"),
    DECODE("decode"),
    ;

    companion object {
        /** Blank and future binding values fail into the bounded [UNKNOWN] bucket. */
        fun fromBinding(value: String?): BrokerNativeFailureKind = when (value?.trim()) {
            CANCELLED.value -> CANCELLED
            TIMEOUT.value -> TIMEOUT
            RATE_LIMITED.value -> RATE_LIMITED
            HTTP_STATUS.value -> HTTP_STATUS
            DNS.value -> DNS
            TLS.value -> TLS
            NETWORK.value -> NETWORK
            VERIFICATION.value -> VERIFICATION
            VALIDATION.value -> VALIDATION
            UNKNOWN.value -> UNKNOWN
            else -> UNKNOWN
        }
    }
}

/**
 * A safe, bounded projection of a failed native request.
 *
 * [httpStatus] and [retryAfterMillis] are null when the generated getter returned zero. [message]
 * is built only from a fixed operation label and the binding's sanitized ErrorText; request JSON,
 * response bodies, result stringification, tickets, and returned WSS URLs are never attached.
 */
class BrokerNativeFailure(
    val kind: BrokerNativeFailureKind,
    val httpStatus: Int? = null,
    val retryAfterMillis: Long? = null,
    message: String,
    cause: Throwable? = null,
) : IOException(sanitizeBrokerFailureMessage(message), cause) {
    val isLocalPlatformFailure: Boolean
        get() = kind == BrokerNativeFailureKind.VALIDATION ||
            kind == BrokerNativeFailureKind.UNAVAILABLE ||
            kind == BrokerNativeFailureKind.DECODE
}

/** Common, platform-owned result shape copied out of gomobile before the operation is closed. */
interface NativeBrokerResult {
    val succeeded: Boolean
    val errorKind: String
    val errorText: String
    val httpStatus: Int
    val retryAfterMillis: Long
}

data class NativeBrokerCommonResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
) : NativeBrokerResult

data class NativeBrokerRelayResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
    val brokerUrl: String = "",
    val relayJson: String = "",
    val keyId: String = "",
    val signatureVerified: Boolean = false,
) : NativeBrokerResult {
    override fun toString(): String =
        "NativeBrokerRelayResult(" +
            "succeeded=$succeeded, errorKind=${BrokerNativeFailureKind.fromBinding(errorKind).value}, " +
            "httpStatus=$httpStatus, retryAfterMillis=$retryAfterMillis, " +
            "brokerUrl=$brokerUrl, relayJson=<redacted>, keyId=$keyId, " +
            "signatureVerified=$signatureVerified)"
}

data class NativeBrokerSpeedTestResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
    val bytes: Long = 0,
    val ttfbMillis: Long = 0,
    val downloadDurationMillis: Long = 0,
    val totalDurationMillis: Long = 0,
    val mbps: Double = 0.0,
) : NativeBrokerResult

data class NativeBrokerManifestResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
    val bodyJson: String = "",
    val sourceUrl: String = "",
) : NativeBrokerResult {
    override fun toString(): String =
        "NativeBrokerManifestResult(" +
            "succeeded=$succeeded, errorKind=${BrokerNativeFailureKind.fromBinding(errorKind).value}, " +
            "httpStatus=$httpStatus, retryAfterMillis=$retryAfterMillis, " +
            "bodyJson=<redacted>, sourceUrl=$sourceUrl)"
}

/**
 * Ticket snapshot with an explicitly redacted representation. The bearer and bound URL are still
 * available as fields for the immediate WSS handoff, but neither can leak through ordinary logs.
 */
class NativeBrokerWssTicketResult(
    override val succeeded: Boolean,
    override val errorKind: String = "",
    override val errorText: String = "",
    override val httpStatus: Int = 0,
    override val retryAfterMillis: Long = 0,
    val ticket: String = "",
    val url: String = "",
    val expiresAtMillis: Long = 0,
) : NativeBrokerResult {
    override fun toString(): String =
        "NativeBrokerWssTicketResult(" +
            "succeeded=$succeeded, errorKind=${BrokerNativeFailureKind.fromBinding(errorKind).value}, " +
            "httpStatus=$httpStatus, retryAfterMillis=$retryAfterMillis, " +
            "ticket=<redacted>, url=<redacted>, expiresAtMillis=$expiresAtMillis)"
}

/** One single-use operation. Tests implement this interface without loading gomobile or Go. */
interface NativeBrokerOperation {
    fun firstReachable(
        primary: String,
        limit: Int,
        clientId: String,
        sessionId: String,
    ): NativeBrokerRelayResult?

    fun sendTelemetryBatchJSON(
        brokerUrl: String,
        batchJson: String,
    ): NativeBrokerCommonResult?

    fun runSpeedTest(brokerUrl: String): NativeBrokerSpeedTestResult?

    fun fetchManifestCandidate(candidateUrl: String): NativeBrokerManifestResult?

    fun requestWSSTicket(
        brokerUrl: String,
        relayId: String,
        frontId: String,
        clientId: String,
        sessionId: String,
    ): NativeBrokerWssTicketResult?

    fun close()
}

fun interface NativeBrokerOperationFactory {
    fun create(): NativeBrokerOperation
}

/**
 * Platform-owned constructor seam: JVM tests can assert Android metadata without constructing a
 * generated object, while production alone delegates to Libbox's Android constructor.
 */
internal fun interface AndroidBrokerOperationConstructor {
    fun create(appVersion: String, apiLevel: String): NativeBrokerOperation?
}

internal class AndroidNativeBrokerOperationFactory(
    private val constructor: AndroidBrokerOperationConstructor = LibboxAndroidBrokerOperationConstructor,
    internal val appVersion: String = BuildConfig.VERSION_NAME,
    internal val apiLevel: String = Build.VERSION.SDK_INT.toString(),
) : NativeBrokerOperationFactory {
    override fun create(): NativeBrokerOperation {
        val operation = try {
            constructor.create(appVersion, apiLevel)
        } catch (error: LinkageError) {
            throw unavailableNativeBrokerFailure(error)
        }
        return operation ?: throw unavailableNativeBrokerFailure()
    }
}

/**
 * Separate constructor seam for React Native operations. The OS token is deliberately fixed by
 * the platform factory rather than accepted from JavaScript.
 */
internal fun interface ReactNativeBrokerOperationConstructor {
    fun create(appVersion: String, osToken: String): NativeBrokerOperation?
}

internal class AndroidReactNativeBrokerOperationFactory(
    private val constructor: ReactNativeBrokerOperationConstructor =
        LibboxReactNativeBrokerOperationConstructor,
    internal val appVersion: String = BuildConfig.VERSION_NAME,
) : NativeBrokerOperationFactory {
    override fun create(): NativeBrokerOperation {
        val operation = try {
            constructor.create(appVersion, ANDROID_REACT_NATIVE_TOKEN)
        } catch (error: LinkageError) {
            throw unavailableNativeBrokerFailure(error)
        }
        return operation ?: throw unavailableNativeBrokerFailure()
    }

    private companion object {
        const val ANDROID_REACT_NATIVE_TOKEN = "android"
    }
}

/** Production composition point shared only by Android VPN-service clients. */
internal object NativeBrokerTransport {
    val operationFactory: NativeBrokerOperationFactory = AndroidNativeBrokerOperationFactory()
}

/** Production composition point for the dedicated React Native bridge. */
internal object ReactNativeBrokerTransport {
    val operationFactory: NativeBrokerOperationFactory = AndroidReactNativeBrokerOperationFactory()
}

private object LibboxAndroidBrokerOperationConstructor : AndroidBrokerOperationConstructor {
    override fun create(appVersion: String, apiLevel: String): NativeBrokerOperation? {
        val operation = Libbox.newOpenRungBrokerOperationForAndroid(appVersion, apiLevel)
            ?: return null
        return LibboxNativeBrokerOperation(operation)
    }
}

private object LibboxReactNativeBrokerOperationConstructor : ReactNativeBrokerOperationConstructor {
    override fun create(appVersion: String, osToken: String): NativeBrokerOperation? {
        val operation = Libbox.newOpenRungBrokerOperationForReactNative(appVersion, osToken)
            ?: return null
        return LibboxNativeBrokerOperation(operation)
    }
}

/**
 * The only Android adapter that knows generated broker types. Every getter is copied immediately
 * into a platform value on the same background invocation, before the runner closes the operation.
 */
private class LibboxNativeBrokerOperation(
    private val operation: OpenRungBrokerOperation,
) : NativeBrokerOperation {
    override fun firstReachable(
        primary: String,
        limit: Int,
        clientId: String,
        sessionId: String,
    ): NativeBrokerRelayResult? = generatedCall {
        operation.firstReachable(primary, limit, clientId, sessionId)?.snapshot()
    }

    override fun sendTelemetryBatchJSON(
        brokerUrl: String,
        batchJson: String,
    ): NativeBrokerCommonResult? = generatedCall {
        operation.sendTelemetryBatchJSON(brokerUrl, batchJson)?.snapshot()
    }

    override fun runSpeedTest(brokerUrl: String): NativeBrokerSpeedTestResult? = generatedCall {
        operation.runSpeedTest(brokerUrl)?.snapshot()
    }

    override fun fetchManifestCandidate(candidateUrl: String): NativeBrokerManifestResult? =
        generatedCall {
            operation.fetchManifestCandidate(candidateUrl)?.snapshot()
        }

    override fun requestWSSTicket(
        brokerUrl: String,
        relayId: String,
        frontId: String,
        clientId: String,
        sessionId: String,
    ): NativeBrokerWssTicketResult? = generatedCall {
        operation.requestWSSTicket(brokerUrl, relayId, frontId, clientId, sessionId)?.snapshot()
    }

    override fun close() {
        generatedCall { operation.close() }
    }
}

private fun OpenRungBrokerResult.snapshot(): NativeBrokerCommonResult =
    NativeBrokerCommonResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = sanitizeNativeErrorText(errorText()),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
    )

private fun OpenRungBrokerRelayResult.snapshot(): NativeBrokerRelayResult =
    NativeBrokerRelayResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = sanitizeNativeErrorText(errorText()),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
        brokerUrl = brokerURL(),
        relayJson = relayJSON(),
        keyId = keyID(),
        signatureVerified = signatureVerified(),
    )

private fun OpenRungBrokerSpeedTestResult.snapshot(): NativeBrokerSpeedTestResult =
    NativeBrokerSpeedTestResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = sanitizeNativeErrorText(errorText()),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
        bytes = bytes(),
        ttfbMillis = ttfbMillis(),
        downloadDurationMillis = downloadDurationMillis(),
        totalDurationMillis = totalDurationMillis(),
        mbps = mbps(),
    )

private fun OpenRungBrokerManifestResult.snapshot(): NativeBrokerManifestResult =
    NativeBrokerManifestResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = sanitizeNativeErrorText(errorText()),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
        bodyJson = bodyJSON(),
        sourceUrl = sourceURL(),
    )

private fun OpenRungBrokerWSSTicketResult.snapshot(): NativeBrokerWssTicketResult =
    NativeBrokerWssTicketResult(
        succeeded = succeeded(),
        errorKind = errorKind(),
        errorText = sanitizeNativeErrorText(errorText()),
        httpStatus = httpStatus(),
        retryAfterMillis = retryAfterMillis(),
        ticket = ticket(),
        url = url(),
        expiresAtMillis = expiresAtMillis(),
    )

private inline fun <T> generatedCall(block: () -> T): T = try {
    block()
} catch (error: LinkageError) {
    throw unavailableNativeBrokerFailure(error)
}

/**
 * Runs one synchronous gomobile selector without ever blocking Main.
 *
 * Cancellation dispatches Close to another IO worker before structured concurrency waits for the
 * blocking child. A second idempotent Close always runs from NonCancellable IO. The post-await
 * cancellation check prevents a success racing with cancellation from being committed by callers.
 */
internal suspend fun <T> runNativeBrokerOperation(
    factory: NativeBrokerOperationFactory,
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    call: (NativeBrokerOperation) -> T,
): T {
    val operation = factory.create()
    try {
        return coroutineScope {
            val worker = async(ioDispatcher) { call(operation) }
            try {
                worker.await().also { currentCoroutineContext().ensureActive() }
            } catch (cancellation: CancellationException) {
                withContext(NonCancellable + ioDispatcher) {
                    closeNativeOperation(operation)
                }
                throw cancellation
            }
        }
    } finally {
        withContext(NonCancellable + ioDispatcher) {
            closeNativeOperation(operation)
        }
    }
}

/** Turns an unsuccessful or nil snapshot into the bounded native failure contract. */
internal fun <T : NativeBrokerResult> requireNativeBrokerSuccess(
    result: T?,
    operationName: String,
): T {
    if (result == null) {
        throw BrokerNativeFailure(
            kind = BrokerNativeFailureKind.UNAVAILABLE,
            message = "$operationName returned no native result",
        )
    }
    if (result.succeeded) return result

    val kind = BrokerNativeFailureKind.fromBinding(result.errorKind)
    val detail = sanitizeNativeErrorText(result.errorText)
    val message = if (detail.isEmpty()) {
        "$operationName failed"
    } else {
        "$operationName failed: $detail"
    }
    if (kind == BrokerNativeFailureKind.CANCELLED) {
        throw CancellationException(message)
    }
    throw BrokerNativeFailure(
        kind = kind,
        httpStatus = result.httpStatus.takeIf { it != 0 },
        retryAfterMillis = result.retryAfterMillis.takeIf { it > 0 },
        message = message,
    )
}

internal fun unavailableNativeBrokerFailure(cause: Throwable? = null): BrokerNativeFailure =
    BrokerNativeFailure(
        kind = BrokerNativeFailureKind.UNAVAILABLE,
        message = "native broker transport is unavailable",
        cause = cause,
    )

private fun closeNativeOperation(operation: NativeBrokerOperation) {
    // Preserve the request outcome if a stale artifact also fails during idempotent cleanup.
    runCatching { operation.close() }
}

private const val MAX_NATIVE_ERROR_BYTES = 256

internal fun sanitizeNativeErrorText(value: String?): String {
    val safe = buildString {
        value.orEmpty().forEach { character ->
            when {
                character == '\r' || character == '\n' || character == '\t' -> append(' ')
                character.isISOControl() -> Unit
                else -> append(character)
            }
        }
    }.trim()
    return truncateUtf8(safe, MAX_NATIVE_ERROR_BYTES)
}

private fun sanitizeBrokerFailureMessage(value: String): String =
    truncateUtf8(sanitizeNativeErrorText(value), MAX_NATIVE_ERROR_BYTES)

private fun truncateUtf8(value: String, maxBytes: Int): String {
    val bytes = value.toByteArray(Charsets.UTF_8)
    if (bytes.size <= maxBytes) return value
    var end = maxBytes
    while (end > 0 && (bytes[end].toInt() and 0xC0) == 0x80) end--
    return String(bytes, 0, end, Charsets.UTF_8)
}
