package com.openrung.vpn

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PunchRecoveryCircuitBreakerTest {
    private val minimumJitter: (Long, Long) -> Long = { minimum, _ -> minimum }

    @Test
    fun `rapid failures back off exponentially and third opens circuit`() {
        val policy = policy()

        val first = loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000)
        assertRetry(first, expectedCount = 1, expectedDelayMs = 1_600)
        assertTrue(policy.allowsDirectPunch(RELAY_A))

        val second = loseAfter(policy, RELAY_A, connectedAtMs = 2_000, lostAtMs = 3_000)
        assertRetry(second, expectedCount = 2, expectedDelayMs = 3_200)
        assertTrue(policy.allowsDirectPunch(RELAY_A))

        val third = loseAfter(policy, RELAY_A, connectedAtMs = 4_000, lostAtMs = 5_000)
        val fallback = third as PunchRecoveryDecision.UseRelayHub
        assertEquals(3, fallback.rapidFailureCount)
        assertEquals(6_400L, fallback.delayMs)
        assertEquals(1_000L, fallback.directUptimeMs)
        assertFalse(policy.allowsDirectPunch(RELAY_A))
    }

    @Test
    fun `short successful reconnect does not reset rapid failure streak`() {
        val policy = policy()

        assertRetry(
            loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000),
            expectedCount = 1,
            expectedDelayMs = 1_600,
        )
        assertRetry(
            loseAfter(
                policy,
                RELAY_A,
                connectedAtMs = 10_000,
                lostAtMs = 10_000 + PunchRecoveryCircuitBreaker.STABLE_PATH_MS - 1,
            ),
            expectedCount = 2,
            expectedDelayMs = 3_200,
        )
    }

    @Test
    fun `stable direct path resets the earlier streak before counting current loss`() {
        val policy = policy()
        loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000)
        loseAfter(policy, RELAY_A, connectedAtMs = 2_000, lostAtMs = 3_000)

        val afterStable = loseAfter(
            policy,
            RELAY_A,
            connectedAtMs = 10_000,
            lostAtMs = 10_000 + PunchRecoveryCircuitBreaker.STABLE_PATH_MS,
        )

        assertRetry(afterStable, expectedCount = 1, expectedDelayMs = 1_600)
        assertTrue(policy.allowsDirectPunch(RELAY_A))
    }

    @Test
    fun `physical network outage adds no failure or backoff`() {
        val policy = policy()
        loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000)

        policy.markDirectConnected(RELAY_A, 2_000)
        val offline = policy.onDirectPathLost(
            relayId = RELAY_A,
            nowElapsedMs = 3_000,
            countTowardBreaker = false,
        ) as PunchRecoveryDecision.RetryDirect

        assertEquals(1, offline.rapidFailureCount)
        assertEquals(0L, offline.delayMs)
        assertFalse(offline.countedFailure)

        val nextCounted = loseAfter(policy, RELAY_A, connectedAtMs = 4_000, lostAtMs = 5_000)
        assertRetry(nextCounted, expectedCount = 2, expectedDelayMs = 3_200)
    }

    @Test
    fun `stable path clears prior failures even when its loss was a network outage`() {
        val policy = policy()
        loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000)

        policy.markDirectConnected(RELAY_A, 2_000)
        val offline = policy.onDirectPathLost(
            relayId = RELAY_A,
            nowElapsedMs = 2_000 + PunchRecoveryCircuitBreaker.STABLE_PATH_MS,
            countTowardBreaker = false,
        ) as PunchRecoveryDecision.RetryDirect

        assertEquals(0, offline.rapidFailureCount)
        assertEquals(0L, offline.delayMs)
    }

    @Test
    fun `breaker state is isolated by relay and explicit reset reopens all circuits`() {
        val policy = policy(maxRapidFailures = 1)
        loseAfter(policy, RELAY_A, connectedAtMs = 0, lostAtMs = 1_000)

        assertFalse(policy.allowsDirectPunch(RELAY_A))
        assertTrue(policy.allowsDirectPunch(RELAY_B))

        policy.reset()

        assertTrue(policy.allowsDirectPunch(RELAY_A))
        assertTrue(policy.allowsDirectPunch(RELAY_B))
    }

    @Test
    fun `exponential delay is capped before jitter`() {
        val policy = policy(
            maxRapidFailures = 10,
            initialBackoffMs = 100,
            maxBackoffMs = 250,
        )

        val delays = (1..5).map { index ->
            val connectedAt = index * 1_000L
            val decision = loseAfter(policy, RELAY_A, connectedAt, connectedAt + 1)
            (decision as PunchRecoveryDecision.RetryDirect).delayMs
        }

        assertEquals(listOf(80L, 160L, 200L, 200L, 200L), delays)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `pending backoff is cancellable before recovery continues`() = runTest {
        val decision = PunchRecoveryDecision.RetryDirect(
            delayMs = 10_000,
            rapidFailureCount = 1,
            directUptimeMs = 1_000,
            countedFailure = true,
        )
        var continued = false
        val recovery = launch {
            decision.awaitBackoff()
            continued = true
        }

        runCurrent()
        advanceTimeBy(5_000)
        recovery.cancel()
        runCurrent()

        assertFalse(continued)
        assertTrue(recovery.isCancelled)
    }

    private fun policy(
        maxRapidFailures: Int = PunchRecoveryCircuitBreaker.MAX_RAPID_FAILURES,
        initialBackoffMs: Long = PunchRecoveryCircuitBreaker.INITIAL_BACKOFF_MS,
        maxBackoffMs: Long = PunchRecoveryCircuitBreaker.MAX_BACKOFF_MS,
    ): PunchRecoveryCircuitBreaker = PunchRecoveryCircuitBreaker(
        maxRapidFailures = maxRapidFailures,
        initialBackoffMs = initialBackoffMs,
        maxBackoffMs = maxBackoffMs,
        chooseJitteredDelay = minimumJitter,
    )

    private fun loseAfter(
        policy: PunchRecoveryCircuitBreaker,
        relayId: String,
        connectedAtMs: Long,
        lostAtMs: Long,
    ): PunchRecoveryDecision {
        policy.markDirectConnected(relayId, connectedAtMs)
        return policy.onDirectPathLost(relayId, lostAtMs, countTowardBreaker = true)
    }

    private fun assertRetry(
        decision: PunchRecoveryDecision,
        expectedCount: Int,
        expectedDelayMs: Long,
    ) {
        val retry = decision as PunchRecoveryDecision.RetryDirect
        assertEquals(expectedCount, retry.rapidFailureCount)
        assertEquals(expectedDelayMs, retry.delayMs)
        assertTrue(retry.countedFailure)
    }

    companion object {
        private const val RELAY_A = "relay-a"
        private const val RELAY_B = "relay-b"
    }
}
