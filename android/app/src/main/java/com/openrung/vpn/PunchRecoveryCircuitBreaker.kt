package com.openrung.vpn

import kotlinx.coroutines.delay
import kotlin.random.Random

internal sealed interface PunchRecoveryDecision {
    val delayMs: Long
    val rapidFailureCount: Int
    val directUptimeMs: Long

    data class RetryDirect(
        override val delayMs: Long,
        override val rapidFailureCount: Int,
        override val directUptimeMs: Long,
        val countedFailure: Boolean,
    ) : PunchRecoveryDecision

    data class UseRelayHub(
        override val delayMs: Long,
        override val rapidFailureCount: Int,
        override val directUptimeMs: Long,
    ) : PunchRecoveryDecision
}

/**
 * Bounds recovery churn from a direct path that repeatedly reaches CONNECTED and then dies.
 *
 * State is per relay so one unstable volunteer does not disable direct paths to other volunteers.
 * The service owns this object on its Main dispatcher; no internal synchronization is needed.
 */
internal class PunchRecoveryCircuitBreaker(
    private val stablePathMs: Long = STABLE_PATH_MS,
    private val maxRapidFailures: Int = MAX_RAPID_FAILURES,
    private val initialBackoffMs: Long = INITIAL_BACKOFF_MS,
    private val maxBackoffMs: Long = MAX_BACKOFF_MS,
    private val chooseJitteredDelay: (minimumMs: Long, maximumMs: Long) -> Long =
        { minimumMs, maximumMs ->
            if (minimumMs == maximumMs) {
                minimumMs
            } else {
                Random.nextLong(minimumMs, maximumMs + 1)
            }
        },
) {
    init {
        require(stablePathMs > 0) { "stablePathMs must be positive" }
        require(maxRapidFailures > 0) { "maxRapidFailures must be positive" }
        require(initialBackoffMs > 0) { "initialBackoffMs must be positive" }
        require(maxBackoffMs >= initialBackoffMs) {
            "maxBackoffMs must be at least initialBackoffMs"
        }
    }

    private data class RelayState(
        var rapidFailureCount: Int = 0,
        var directConnectedAtMs: Long? = null,
        var circuitOpen: Boolean = false,
    )

    private val relayStates = mutableMapOf<String, RelayState>()

    fun markDirectConnected(relayId: String, nowElapsedMs: Long) {
        require(relayId.isNotBlank()) { "relayId must not be blank" }
        relayStates.getOrPut(relayId, ::RelayState).directConnectedAtMs = nowElapsedMs
    }

    fun allowsDirectPunch(relayId: String): Boolean = relayStates[relayId]?.circuitOpen != true

    /**
     * Records a lost direct path and returns the recovery action. A physical-network outage passes
     * [countTowardBreaker] as false: it preserves any earlier rapid-failure streak, adds no delay,
     * and never opens the circuit. A path that survived [stablePathMs] clears the earlier streak
     * before the current loss is considered.
     */
    fun onDirectPathLost(
        relayId: String,
        nowElapsedMs: Long,
        countTowardBreaker: Boolean,
    ): PunchRecoveryDecision {
        require(relayId.isNotBlank()) { "relayId must not be blank" }
        val state = relayStates.getOrPut(relayId, ::RelayState)
        val connectedAtMs = state.directConnectedAtMs
        state.directConnectedAtMs = null
        val directUptimeMs = connectedAtMs
            ?.let { (nowElapsedMs - it).coerceAtLeast(0) }
            ?: 0

        if (directUptimeMs >= stablePathMs) {
            state.rapidFailureCount = 0
            state.circuitOpen = false
        }

        if (!countTowardBreaker) {
            return PunchRecoveryDecision.RetryDirect(
                delayMs = 0,
                rapidFailureCount = state.rapidFailureCount,
                directUptimeMs = directUptimeMs,
                countedFailure = false,
            )
        }

        state.rapidFailureCount++
        val delayMs = recoveryDelayMs(state.rapidFailureCount)
        if (state.rapidFailureCount >= maxRapidFailures) {
            state.circuitOpen = true
            return PunchRecoveryDecision.UseRelayHub(
                delayMs = delayMs,
                rapidFailureCount = state.rapidFailureCount,
                directUptimeMs = directUptimeMs,
            )
        }

        return PunchRecoveryDecision.RetryDirect(
            delayMs = delayMs,
            rapidFailureCount = state.rapidFailureCount,
            directUptimeMs = directUptimeMs,
            countedFailure = true,
        )
    }

    /** Explicit user connect/disconnect starts a new recovery epoch. */
    fun reset() {
        relayStates.clear()
    }

    private fun recoveryDelayMs(failureCount: Int): Long {
        var nominalMs = initialBackoffMs
        repeat((failureCount - 1).coerceAtLeast(0)) {
            nominalMs = if (nominalMs >= maxBackoffMs / 2) {
                maxBackoffMs
            } else {
                (nominalMs * 2).coerceAtMost(maxBackoffMs)
            }
        }
        val jitterMs = nominalMs / JITTER_DIVISOR
        val minimumMs = (nominalMs - jitterMs).coerceAtLeast(1)
        val maximumMs = (nominalMs + jitterMs).coerceAtMost(maxBackoffMs)
        return chooseJitteredDelay(minimumMs, maximumMs).coerceIn(minimumMs, maximumMs)
    }

    companion object {
        internal const val STABLE_PATH_MS = 5 * 60_000L
        internal const val MAX_RAPID_FAILURES = 3
        internal const val INITIAL_BACKOFF_MS = 2_000L
        internal const val MAX_BACKOFF_MS = 30_000L
        private const val JITTER_DIVISOR = 5L // +/-20 percent
    }
}

/** Kept as a suspend operation so disconnect or a manual reconnect cancels pending backoff. */
internal suspend fun PunchRecoveryDecision.awaitBackoff() {
    if (delayMs > 0) delay(delayMs)
}
