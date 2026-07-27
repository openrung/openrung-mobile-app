package com.openrung.net

import com.openrung.model.RelayListResponse
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json

/** Thin Android adapter over brokerapi's verified, ECH-capable FirstReachable operation. */
object BrokerClient {
    /** A verified relay list together with the exact broker front selected by brokerapi. */
    data class Fetch(val brokerUrl: String, val response: RelayListResponse)

    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Delegates candidate policy, staggered racing, transport selection, and relay verification to
     * brokerapi. Optional identity values become empty strings; Go enforces that a non-empty
     * identity is a complete client/session pair.
     */
    suspend fun firstReachable(
        primary: String,
        limit: Int = 5,
        clientId: String? = null,
        sessionId: String? = null,
    ): Fetch = firstReachable(
        primary = primary,
        limit = limit,
        clientId = clientId,
        sessionId = sessionId,
        operationFactory = NativeBrokerTransport.operationFactory,
    )

    internal suspend fun firstReachable(
        primary: String,
        limit: Int,
        clientId: String?,
        sessionId: String?,
        operationFactory: NativeBrokerOperationFactory,
        decoder: Json = json,
    ): Fetch {
        val native = runNativeBrokerOperation(operationFactory) { operation ->
            operation.firstReachable(
                primary = primary,
                limit = limit,
                clientId = clientId.orEmpty(),
                sessionId = sessionId.orEmpty(),
            )
        }
        val result = requireNativeBrokerSuccess(native, "native broker discovery")
        if (result.brokerUrl.isBlank()) {
            throw BrokerNativeFailure(
                kind = BrokerNativeFailureKind.VALIDATION,
                message = "native broker discovery returned no winning broker URL",
            )
        }
        val response = try {
            decoder.decodeFromString<RelayListResponse>(result.relayJson)
        } catch (_: SerializationException) {
            // Parser diagnostics can quote the relay payload. Keep the local incompatibility fixed,
            // typed, and free of response bytes; Go has already selected and verified this winner.
            throw BrokerNativeFailure(
                kind = BrokerNativeFailureKind.DECODE,
                message = "native broker relay JSON is incompatible with the Android model",
            )
        }
        return Fetch(brokerUrl = result.brokerUrl, response = response)
    }
}
