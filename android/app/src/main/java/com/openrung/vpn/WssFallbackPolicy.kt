package com.openrung.vpn

import com.openrung.model.RelayConstants
import com.openrung.model.RelayDescriptor
import com.openrung.model.WssFrontDescriptor
import java.util.Collections
import java.util.IdentityHashMap
import java.util.concurrent.CancellationException

/**
 * The direct Reality data path failed after local setup completed. This is the sole exception type
 * that is allowed to unlock WSS fallback.
 */
class DirectPathException(
    val stage: String,
    cause: Throwable,
) : Exception("direct Reality path failed at $stage: ${cause.message ?: cause.javaClass.simpleName}", cause)

/** A device, permission, tunnel-engine, configuration, or other local setup failure. */
class LocalTunnelException(
    val stage: String,
    cause: Throwable,
) : Exception("local tunnel failed at $stage: ${cause.message ?: cause.javaClass.simpleName}", cause)

/** A failure confined to one WSS/CDN access path. */
class WssTransportException(
    val stage: String,
    val frontId: String,
    cause: Throwable,
) : Exception(
    "WSS front $frontId failed at $stage: ${cause.message ?: cause.javaClass.simpleName}",
    cause,
)

/**
 * Marks an exhausted WSS fallback after the direct-fallback callback has returned, so an outer
 * relay ladder does not apply a second health penalty for the same direct relay failure.
 */
class RelayFailureAlreadyRecordedException(
    val directFailure: DirectPathException,
    val wssFailures: List<WssTransportException>,
) : Exception(
    buildString {
        append(directFailure.message)
        append("; all WSS fronts failed")
        wssFailures.lastOrNull()?.message?.let {
            append(": ")
            append(it)
        }
    },
    wssFailures.lastOrNull() ?: directFailure,
) {
    val lastWssFailure: WssTransportException?
        get() = wssFailures.lastOrNull()
}

/** Cycle-safe marker lookup for callers that add their own exception wrappers. */
fun relayFailureAlreadyRecorded(error: Throwable): Boolean =
    error.causeChain().any { it is RelayFailureAlreadyRecordedException }

/**
 * Adapter boundary for the Go/libbox validation entry point backed by `wsscore.NormalizeFronts`.
 *
 * Kotlin deliberately does not duplicate WSS URL, protocol-version, canonicalization, uniqueness,
 * or sorting rules. Production supplies the normalized fronts returned by Go; only an exact match
 * with the signed descriptor is eligible.
 */
fun interface WssFrontSetValidator {
    @Throws(Exception::class)
    fun normalize(fronts: List<WssFrontDescriptor>): List<WssFrontDescriptor>
}

/** Pure direct-first WSS fallback policy shared by the Android service and JVM tests. */
class WssFallbackPolicy(
    private val frontSetValidator: WssFrontSetValidator,
) {
    /** Returns the exact signed fronts in their advertised order, or an empty list if ineligible. */
    fun supportedFronts(relay: RelayDescriptor): List<WssFrontDescriptor> {
        val transport = relay.transport.trim().lowercase()
        if (transport.isNotEmpty() && transport != RelayConstants.TRANSPORT_DIRECT) {
            return emptyList()
        }
        if (relay.nodeClass != RelayConstants.NODE_CLASS_FOUNDATION ||
            relay.exitMode != RelayConstants.EXIT_MODE_DIRECT ||
            relay.publicPort != 443 ||
            relay.wssFronts.isEmpty()
        ) {
            return emptyList()
        }

        val normalized = try {
            frontSetValidator.normalize(relay.wssFronts)
        } catch (cancellation: CancellationException) {
            throw cancellation
        } catch (_: Exception) {
            return emptyList()
        }
        if (normalized != relay.wssFronts) return emptyList()
        return relay.wssFronts.toList()
    }

    /**
     * Attempts direct Reality exactly once. Only [DirectPathException] can begin WSS attempts.
     * Fronts are tried sequentially in the exact signed order returned by [supportedFronts].
     *
     * [onDirectFallback] is the service's point to record the direct relay failure and fallback
     * telemetry once. [onWssFailure] is transport-only telemetry and must not affect relay health.
     */
    suspend fun <T> connect(
        relay: RelayDescriptor,
        attemptDirect: suspend () -> T,
        attemptWss: suspend (WssFrontDescriptor) -> T,
        onDirectFallback: suspend (DirectPathException) -> Unit,
        onWssFailure: suspend (WssFrontDescriptor, WssTransportException) -> Unit,
    ): T {
        val directFailure = try {
            return attemptDirect()
        } catch (error: Throwable) {
            error.cancellationCause()?.let { throw it }
            if (error !is DirectPathException) throw error
            error
        }

        val fronts = supportedFronts(relay)
        if (fronts.isEmpty()) throw directFailure

        onDirectFallback(directFailure)
        val wssFailures = ArrayList<WssTransportException>(fronts.size)
        for (front in fronts) {
            try {
                return attemptWss(front)
            } catch (error: Throwable) {
                error.cancellationCause()?.let { throw it }
                when (error) {
                    is LocalTunnelException -> throw error
                    is WssTransportException -> {
                        wssFailures.add(error)
                        onWssFailure(front, error)
                    }
                    else -> throw error
                }
            }
        }

        throw RelayFailureAlreadyRecordedException(directFailure, wssFailures.toList())
    }
}

private fun Throwable.cancellationCause(): CancellationException? =
    causeChain().firstNotNullOfOrNull { it as? CancellationException }

private fun Throwable.causeChain(): List<Throwable> {
    val chain = ArrayList<Throwable>()
    val seen = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
    var current: Throwable? = this
    while (current != null && seen.add(current)) {
        chain.add(current)
        current = current.cause
    }
    return chain
}
