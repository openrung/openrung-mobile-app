package com.openrung.net

import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicInteger

internal data class FirstReachableCall(
    val primary: String,
    val limit: Int,
    val clientId: String,
    val sessionId: String,
)

internal data class TelemetryCall(
    val brokerUrl: String,
    val batchJson: String,
)

internal data class WssTicketCall(
    val brokerUrl: String,
    val relayId: String,
    val frontId: String,
    val clientId: String,
    val sessionId: String,
)

/** Pure JVM fake: no generated gomobile class is referenced or instantiated. */
internal open class RecordingNativeBrokerOperation : NativeBrokerOperation {
    val firstReachableCalls = mutableListOf<FirstReachableCall>()
    val telemetryCalls = mutableListOf<TelemetryCall>()
    val wssTicketCalls = mutableListOf<WssTicketCall>()
    val closeCalls = AtomicInteger()

    var relayResult: NativeBrokerRelayResult? = NativeBrokerRelayResult(succeeded = true)
    var telemetryResult: NativeBrokerCommonResult? = NativeBrokerCommonResult(succeeded = true)
    var wssTicketResult: NativeBrokerWssTicketResult? =
        NativeBrokerWssTicketResult(succeeded = true)

    var firstReachableBlock: (() -> NativeBrokerRelayResult?)? = null
    var telemetryBlock: (() -> NativeBrokerCommonResult?)? = null
    var wssTicketBlock: (() -> NativeBrokerWssTicketResult?)? = null
    var closeBlock: (() -> Unit)? = null

    override fun firstReachable(
        primary: String,
        limit: Int,
        clientId: String,
        sessionId: String,
    ): NativeBrokerRelayResult? {
        synchronized(firstReachableCalls) {
            firstReachableCalls += FirstReachableCall(primary, limit, clientId, sessionId)
        }
        return firstReachableBlock?.invoke() ?: relayResult
    }

    override fun sendTelemetryBatchJSON(
        brokerUrl: String,
        batchJson: String,
    ): NativeBrokerCommonResult? {
        synchronized(telemetryCalls) {
            telemetryCalls += TelemetryCall(brokerUrl, batchJson)
        }
        return telemetryBlock?.invoke() ?: telemetryResult
    }

    override fun requestWSSTicket(
        brokerUrl: String,
        relayId: String,
        frontId: String,
        clientId: String,
        sessionId: String,
    ): NativeBrokerWssTicketResult? {
        synchronized(wssTicketCalls) {
            wssTicketCalls += WssTicketCall(brokerUrl, relayId, frontId, clientId, sessionId)
        }
        return wssTicketBlock?.invoke() ?: wssTicketResult
    }

    override fun close() {
        closeCalls.incrementAndGet()
        closeBlock?.invoke()
    }
}

internal class RecordingNativeBrokerOperationFactory(
    vararg operations: NativeBrokerOperation,
) : NativeBrokerOperationFactory {
    private val operations = ArrayDeque(operations.toList())
    val createCalls = AtomicInteger()

    override fun create(): NativeBrokerOperation = synchronized(operations) {
        createCalls.incrementAndGet()
        check(operations.isNotEmpty()) { "fake native operation queue is empty" }
        operations.removeFirst()
    }
}

internal suspend inline fun <reified T : Throwable> assertSuspendThrows(
    crossinline block: suspend () -> Unit,
): T {
    try {
        block()
    } catch (error: Throwable) {
        if (error is T) return error
        throw AssertionError("expected ${T::class.java.name}, got ${error::class.java.name}", error)
    }
    throw AssertionError("expected ${T::class.java.name}")
}
