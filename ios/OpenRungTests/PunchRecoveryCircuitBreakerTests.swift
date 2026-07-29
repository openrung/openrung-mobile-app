import XCTest

final class PunchRecoveryCircuitBreakerTests: XCTestCase {
    private let relayA = "relay-a"
    private let relayB = "relay-b"

    func testRapidFailuresBackOffExponentiallyAndThirdOpensCircuit() {
        let policy = makePolicy()

        let first = loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000)
        assertRetry(first, expectedCount: 1, expectedDelay: 1_600)
        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayA))

        let second = loseAfter(policy, relayID: relayA, connectedAt: 2_000, lostAt: 3_000)
        assertRetry(second, expectedCount: 2, expectedDelay: 3_200)
        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayA))

        let third = loseAfter(policy, relayID: relayA, connectedAt: 4_000, lostAt: 5_000)
        guard case let .useRelayHub(delay, count, uptime, counted) = third else {
            return XCTFail("third rapid failure must use RelayHub")
        }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(delay, 6_400)
        XCTAssertEqual(uptime, 1_000)
        XCTAssertTrue(counted)
        XCTAssertFalse(policy.allowsDirectPunch(relayID: relayA))
    }

    func testShortSuccessfulReconnectDoesNotResetRapidFailureStreak() {
        let policy = makePolicy()

        assertRetry(
            loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000),
            expectedCount: 1,
            expectedDelay: 1_600
        )
        assertRetry(
            loseAfter(
                policy,
                relayID: relayA,
                connectedAt: 10_000,
                lostAt: 10_000 + PunchRecoveryCircuitBreaker.stablePathMilliseconds - 1
            ),
            expectedCount: 2,
            expectedDelay: 3_200
        )
    }

    func testStableDirectPathResetsEarlierStreakBeforeCountingCurrentLoss() {
        let policy = makePolicy()
        _ = loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000)
        _ = loseAfter(policy, relayID: relayA, connectedAt: 2_000, lostAt: 3_000)

        let afterStable = loseAfter(
            policy,
            relayID: relayA,
            connectedAt: 10_000,
            lostAt: 10_000 + PunchRecoveryCircuitBreaker.stablePathMilliseconds
        )

        assertRetry(afterStable, expectedCount: 1, expectedDelay: 1_600)
        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayA))
    }

    func testPhysicalNetworkOutageAddsNoFailureOrBackoff() {
        let policy = makePolicy()
        _ = loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000)

        policy.markDirectConnected(relayID: relayA, nowElapsedMilliseconds: 2_000)
        let offline = policy.onDirectPathLost(
            relayID: relayA,
            nowElapsedMilliseconds: 3_000,
            countTowardBreaker: false
        )

        guard case let .retryDirect(delay, count, uptime, counted) = offline else {
            return XCTFail("physical outage must retry direct")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(delay, 0)
        XCTAssertEqual(uptime, 1_000)
        XCTAssertFalse(counted)

        let nextCounted = loseAfter(
            policy,
            relayID: relayA,
            connectedAt: 4_000,
            lostAt: 5_000
        )
        assertRetry(nextCounted, expectedCount: 2, expectedDelay: 3_200)
    }

    func testStablePathClearsPriorFailuresEvenWhenLossWasNetworkOutage() {
        let policy = makePolicy()
        _ = loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000)

        policy.markDirectConnected(relayID: relayA, nowElapsedMilliseconds: 2_000)
        let offline = policy.onDirectPathLost(
            relayID: relayA,
            nowElapsedMilliseconds:
                2_000 + PunchRecoveryCircuitBreaker.stablePathMilliseconds,
            countTowardBreaker: false
        )

        XCTAssertEqual(offline.rapidFailureCount, 0)
        XCTAssertEqual(offline.delayMilliseconds, 0)
        XCTAssertFalse(offline.countedFailure)
    }

    func testBreakerStateIsPerRelayAndResetReopensAllCircuits() {
        let policy = makePolicy(maximumRapidFailures: 1)
        _ = loseAfter(policy, relayID: relayA, connectedAt: 0, lostAt: 1_000)

        XCTAssertFalse(policy.allowsDirectPunch(relayID: relayA))
        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayB))

        policy.reset()

        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayA))
        XCTAssertTrue(policy.allowsDirectPunch(relayID: relayB))
    }

    func testExponentialDelayIsCappedBeforeJitter() {
        let policy = makePolicy(
            maximumRapidFailures: 10,
            initialBackoffMilliseconds: 100,
            maximumBackoffMilliseconds: 250
        )

        let delays = (1...5).map { index -> UInt64 in
            let connectedAt = UInt64(index) * 1_000
            return loseAfter(
                policy,
                relayID: relayA,
                connectedAt: connectedAt,
                lostAt: connectedAt + 1
            ).delayMilliseconds
        }

        XCTAssertEqual(delays, [80, 160, 200, 200, 200])
    }

    func testJitterSelectorIsClampedToAllowedRange() {
        let belowMinimum = PunchRecoveryCircuitBreaker(chooseJitteredDelay: { _ in 0 })
        XCTAssertEqual(
            loseAfter(belowMinimum, relayID: relayA, connectedAt: 0, lostAt: 1)
                .delayMilliseconds,
            1_600
        )

        let aboveMaximum = PunchRecoveryCircuitBreaker(
            chooseJitteredDelay: { _ in UInt64.max }
        )
        XCTAssertEqual(
            loseAfter(aboveMaximum, relayID: relayA, connectedAt: 0, lostAt: 1)
                .delayMilliseconds,
            2_400
        )
    }

    func testMonotonicClockRegressionProducesZeroUptime() {
        let policy = makePolicy()
        policy.markDirectConnected(relayID: relayA, nowElapsedMilliseconds: 2_000)

        let decision = policy.onDirectPathLost(
            relayID: relayA,
            nowElapsedMilliseconds: 1_000,
            countTowardBreaker: true
        )

        XCTAssertEqual(decision.directUptimeMilliseconds, 0)
        XCTAssertEqual(decision.rapidFailureCount, 1)
    }

    func testPendingBackoffIsCancellationFriendly() async {
        let decision = PunchRecoveryDecision.retryDirect(
            delayMilliseconds: 10_000,
            rapidFailureCount: 1,
            directUptimeMilliseconds: 1_000,
            countedFailure: true
        )
        let waiting = Task {
            try await decision.awaitBackoff()
        }
        await Task.yield()
        waiting.cancel()

        do {
            try await waiting.value
            XCTFail("cancelled backoff unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation prevents recovery from continuing.
        } catch {
            XCTFail("unexpected backoff error: \(error)")
        }
    }

    private func makePolicy(
        maximumRapidFailures: Int = PunchRecoveryCircuitBreaker.maximumRapidFailures,
        initialBackoffMilliseconds: UInt64 =
            PunchRecoveryCircuitBreaker.initialBackoffMilliseconds,
        maximumBackoffMilliseconds: UInt64 =
            PunchRecoveryCircuitBreaker.maximumBackoffMilliseconds
    ) -> PunchRecoveryCircuitBreaker {
        PunchRecoveryCircuitBreaker(
            maximumRapidFailures: maximumRapidFailures,
            initialBackoffMilliseconds: initialBackoffMilliseconds,
            maximumBackoffMilliseconds: maximumBackoffMilliseconds,
            chooseJitteredDelay: { $0.lowerBound }
        )
    }

    private func loseAfter(
        _ policy: PunchRecoveryCircuitBreaker,
        relayID: String,
        connectedAt: UInt64,
        lostAt: UInt64
    ) -> PunchRecoveryDecision {
        policy.markDirectConnected(
            relayID: relayID,
            nowElapsedMilliseconds: connectedAt
        )
        return policy.onDirectPathLost(
            relayID: relayID,
            nowElapsedMilliseconds: lostAt,
            countTowardBreaker: true
        )
    }

    private func assertRetry(
        _ decision: PunchRecoveryDecision,
        expectedCount: Int,
        expectedDelay: UInt64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .retryDirect(delay, count, _, counted) = decision else {
            return XCTFail("expected direct retry", file: file, line: line)
        }
        XCTAssertEqual(count, expectedCount, file: file, line: line)
        XCTAssertEqual(delay, expectedDelay, file: file, line: line)
        XCTAssertTrue(counted, file: file, line: line)
    }
}
