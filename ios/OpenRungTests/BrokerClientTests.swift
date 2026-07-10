import Foundation
import XCTest

/// Tests for the override-first / staggered-race discovery in `BrokerClient.firstReachable`,
/// driven through the internal fetch-injectable overload with a shortened stagger so no real
/// sockets (or real 2.5 s staggers) are involved. Mirrors the reference TypeScript suite
/// (`__tests__/core/brokerClient.test.ts`) and the Kotlin `BrokerClientTest` — the override /
/// race semantics must stay identical across the desktop Go, RN TypeScript, Kotlin and Swift
/// clients.
final class BrokerClientTests: XCTestCase {
    private static let primary = URL(string: "https://primary.example/")!
    private static let fallback = URL(string: "https://fallback.example/")!

    /// Short enough to keep the suite fast, long enough that ordering assertions are unambiguous
    /// against real-clock scheduling jitter.
    private static let staggerMs: UInt64 = 100

    private static let relayList = RelayListResponse(count: 0, serverTime: Date(), relays: [])

    /// Wraps urls as a pure-race candidate list — what `BrokerClient.candidates` builds without
    /// an override.
    private static func noOverride(_ urls: URL...) -> BrokerCandidates {
        BrokerCandidates(urls: urls)
    }

    /// Wraps urls as a candidate list whose FIRST entry is a genuine user override.
    private static func withOverride(_ urls: URL...) -> BrokerCandidates {
        BrokerCandidates(urls: urls, overrideFirst: true)
    }

    private static func sleep(ms: UInt64) async throws {
        try await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// Hangs until the surrounding attempt is cancelled — a blackholed/censored endpoint.
    /// `Task.sleep` rethrows `CancellationError` the moment the attempt is cancelled.
    private static func hangUntilCancelled() async throws -> Never {
        while true {
            try await sleep(ms: 3_600_000)
        }
    }

    /// Thread-safe record of which endpoints were attempted, in start order.
    private actor AttemptLog {
        private(set) var attempts: [URL] = []
        func record(_ url: URL) {
            attempts.append(url)
        }
    }

    private struct AttemptError: Error, Equatable {
        let url: URL
    }

    // Staggered race (spec points 1–5).

    func testHealthyPrimaryWinsWithoutTheFallbackEverStarting() async throws {
        let log = AttemptLog()
        let fetch = try await BrokerClient.firstReachable(
            candidates: Self.noOverride(Self.primary, Self.fallback),
            staggerMs: Self.staggerMs
        ) { url in
            await log.record(url)
            try await Self.sleep(ms: 10) // healthy: answers well inside the first stagger window
            return Self.relayList
        }
        XCTAssertEqual(fetch.brokerURL, Self.primary)
        // Long after the race settled, no leftover stagger sleeper may fire: the fallback front
        // never sees a request while the primary is healthy.
        try await Self.sleep(ms: 3 * Self.staggerMs)
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [Self.primary])
    }

    func testFallbackBeatsAHangingPrimaryOneStaggerInAndTheLoserIsCancelled() async throws {
        let primaryCancelled = expectation(description: "primary attempt cancelled")
        let fetch = try await BrokerClient.firstReachable(
            candidates: Self.noOverride(Self.primary, Self.fallback),
            staggerMs: Self.staggerMs
        ) { url in
            if url == Self.primary {
                do {
                    try await Self.hangUntilCancelled() // blackholed: never answers, never fails
                } catch {
                    primaryCancelled.fulfill()
                    throw error
                }
            }
            return Self.relayList
        }
        // The later candidate that succeeds first wins even though the earlier-priority attempt
        // is still pending — priority is only a head start (spec point 2)...
        XCTAssertEqual(fetch.brokerURL, Self.fallback)
        // ...and the losing attempt was aborted for real, not left running to its timeout.
        await fulfillment(of: [primaryCancelled], timeout: 5)
    }

    func testOneCandidateJoinsTheRacePerStaggerAndALateWinnerCancelsEveryLoser() async throws {
        let a = URL(string: "https://a.example/")!
        let b = URL(string: "https://b.example/")!
        let c = URL(string: "https://c.example/")!
        let log = AttemptLog()
        let losersCancelled = expectation(description: "both losing attempts cancelled")
        losersCancelled.expectedFulfillmentCount = 2
        let fetch = try await BrokerClient.firstReachable(
            candidates: Self.noOverride(a, b, c),
            staggerMs: Self.staggerMs
        ) { url in
            await log.record(url)
            if url != c {
                do {
                    try await Self.hangUntilCancelled()
                } catch {
                    losersCancelled.fulfill()
                    throw error
                }
            }
            return Self.relayList
        }
        XCTAssertEqual(fetch.brokerURL, c)
        // One candidate joined per stagger, in list order; the winner cancelled every loser.
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [a, b, c])
        await fulfillment(of: [losersCancelled], timeout: 5)
    }

    func testAllCandidatesFailingSurfacesThePrimaryError() async {
        do {
            _ = try await BrokerClient.firstReachable(
                candidates: Self.noOverride(Self.primary, Self.fallback),
                staggerMs: Self.staggerMs
            ) { url in
                throw AttemptError(url: url)
            }
            XCTFail("expected the race to fail")
        } catch {
            // The FIRST candidate's failure is the surfaced diagnostic, not the last-observed
            // one (spec point 4).
            XCTAssertEqual(error as? AttemptError, AttemptError(url: Self.primary))
        }
    }

    func testASingleCandidateBehavesExactlyLikeOnePlainAttempt() async {
        let log = AttemptLog()
        let begun = Date()
        do {
            _ = try await BrokerClient.firstReachable(
                candidates: Self.noOverride(Self.primary),
                staggerMs: 600_000 // a stagger sleep would be unmissable (spec point 5)
            ) { url in
                await log.record(url)
                throw AttemptError(url: url)
            }
            XCTFail("expected the attempt to fail")
        } catch {
            // The error propagates unchanged, immediately — no stagger sleeper was scheduled.
            XCTAssertEqual(error as? AttemptError, AttemptError(url: Self.primary))
        }
        XCTAssertLessThan(Date().timeIntervalSince(begun), 60)
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [Self.primary])
    }

    func testAnEmptyCandidateListIsRejectedUpFront() async {
        do {
            _ = try await BrokerClient.firstReachable(
                candidates: BrokerCandidates(urls: []),
                staggerMs: Self.staggerMs
            ) { _ in
                Self.relayList
            }
            XCTFail("expected the empty candidate list to be rejected")
        } catch {
            XCTAssertEqual(error as? BrokerClientError, .invalidResponse)
        }
    }

    // User-override strict phase (spec point 6).

    func testAnOverrideSlowerThanTheStaggerStillWinsAndTheDefaultIsNeverContacted() async throws {
        // The override answers only after 3 stagger intervals: under pure race semantics the
        // default front would long since have won; under override-first it must never even start.
        let log = AttemptLog()
        let fetch = try await BrokerClient.firstReachable(
            candidates: Self.withOverride(Self.primary, Self.fallback),
            staggerMs: Self.staggerMs
        ) { url in
            await log.record(url)
            try await Self.sleep(ms: 3 * Self.staggerMs) // slower than the stagger, inside its timeout
            return Self.relayList
        }
        XCTAssertEqual(fetch.brokerURL, Self.primary)
        // Long after the override won, no default has been contacted — there was never a race.
        try await Self.sleep(ms: 3 * Self.staggerMs)
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [Self.primary])
    }

    func testAnOverrideFailureStartsTheRemainingDefaultsOnTheRaceCadence() async throws {
        let override = URL(string: "https://override.example/")!
        let a = URL(string: "https://a.example/")!
        let b = URL(string: "https://b.example/")!
        let log = AttemptLog()
        let fetch = try await BrokerClient.firstReachable(
            candidates: Self.withOverride(override, a, b),
            staggerMs: Self.staggerMs
        ) { url in
            await log.record(url)
            if url == override {
                throw AttemptError(url: url)
            }
            if url == a {
                try await Self.hangUntilCancelled() // hangs; loses the remainder race
            }
            return Self.relayList
        }
        // The override failed, so the remainder raced on the usual cadence and its second
        // candidate won past the hanging first one.
        XCTAssertEqual(fetch.brokerURL, b)
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [override, a, b])
    }

    func testTheOverrideErrorIsSurfacedWhenTheRemainderRaceAlsoFails() async {
        do {
            _ = try await BrokerClient.firstReachable(
                candidates: Self.withOverride(Self.primary, Self.fallback),
                staggerMs: Self.staggerMs
            ) { url in
                throw AttemptError(url: url)
            }
            XCTFail("expected the override flow to fail")
        } catch {
            // The override is candidates[0]: its error stays the surfaced diagnostic (spec
            // point 4) — the user configured that broker, so its failure is what they need to
            // see, not a default front's.
            XCTAssertEqual(error as? AttemptError, AttemptError(url: Self.primary))
        }
    }

    func testASingleOverriddenCandidateBehavesExactlyLikeOnePlainAttempt() async {
        let log = AttemptLog()
        let begun = Date()
        do {
            _ = try await BrokerClient.firstReachable(
                candidates: Self.withOverride(Self.primary),
                staggerMs: 600_000 // any remainder race would be unmissable
            ) { url in
                await log.record(url)
                throw AttemptError(url: url)
            }
            XCTFail("expected the attempt to fail")
        } catch {
            XCTAssertEqual(error as? AttemptError, AttemptError(url: Self.primary))
        }
        XCTAssertLessThan(Date().timeIntervalSince(begun), 60)
        let attempts = await log.attempts
        XCTAssertEqual(attempts, [Self.primary])
    }

    func testCancellingTheCallerMidRemainderRacePropagatesTheCancellation() async {
        // The override fails fast, the remaining default hangs, then the caller cancels. The
        // surfaced error must be the cancellation — what the caller classifies on — not the
        // override's stale failure.
        let defaultStarted = expectation(description: "default attempt started")
        let task = Task {
            try await BrokerClient.firstReachable(
                candidates: Self.withOverride(Self.primary, Self.fallback),
                staggerMs: Self.staggerMs
            ) { url in
                if url == Self.primary {
                    throw AttemptError(url: url)
                }
                defaultStarted.fulfill()
                try await Self.hangUntilCancelled()
            }
        }
        await fulfillment(of: [defaultStarted], timeout: 5)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected the cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }
}
