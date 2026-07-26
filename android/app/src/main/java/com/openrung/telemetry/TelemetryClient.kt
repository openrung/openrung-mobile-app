package com.openrung.telemetry

import com.openrung.net.NativeBrokerOperationFactory
import com.openrung.net.NativeBrokerTransport
import com.openrung.net.requireNativeBrokerSuccess
import com.openrung.net.runNativeBrokerOperation
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

/** Native telemetry uploader backed by one single-use brokerapi operation per non-empty batch. */
class TelemetryClient(
    private val baseUrl: String,
    private val operationFactory: NativeBrokerOperationFactory = NativeBrokerTransport.operationFactory,
    private val json: Json = Json { encodeDefaults = true },
) {
    suspend fun send(events: List<TelemetryEvent>) {
        if (events.isEmpty()) return

        // Encode once. brokerapi validates this exact UTF-8 JSON and derives the complete identity
        // pair from its events; Android must not construct identity headers independently.
        val batchJson = json.encodeToString(TelemetryBatch(events))
        val native = runNativeBrokerOperation(operationFactory) { operation ->
            operation.sendTelemetryBatchJSON(baseUrl, batchJson)
        }
        requireNativeBrokerSuccess(native, "native telemetry upload")
    }
}
