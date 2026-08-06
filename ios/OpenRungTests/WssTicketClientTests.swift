import Foundation
import XCTest

final class WssTicketClientTests: XCTestCase {
    private static let primary = URL(string: "https://primary.example/")!
    private static let secondary = URL(string: "https://secondary.example/")!
    private static let frontURL = "wss://a.cdn.example/connect"

    func testRequestOnceForwardsEveryFieldAndConvertsExpiry() async throws {
        struct Invocation: Equatable {
            let brokerURL: String
            let relayID: String
            let frontID: String
            let clientID: String
            let sessionID: String
        }
        let expiryMilliseconds: Int64 = 1_753_142_520_123
        let invocation = TestLockedBox<Invocation?>(nil)
        let operation = TestNativeBrokerOperation()
        operation.ticketHandler = { brokerURL, relayID, frontID, clientID, sessionID in
            invocation.set(
                Invocation(
                    brokerURL: brokerURL,
                    relayID: relayID,
                    frontID: frontID,
                    clientID: clientID,
                    sessionID: sessionID
                )
            )
            return NativeBrokerWSSTicketResultSnapshot(
                succeeded: true,
                ticket: "opaque-ticket",
                url: Self.frontURL,
                expiresAtMilliseconds: expiryMilliseconds
            )
        }

        let result = try await WssTicketClient.requestOnce(
            operationFactory: TestNativeBrokerFactory(operation: operation),
            brokerURL: Self.primary,
            relayID: "relay-a",
            frontID: "front-a",
            clientID: "client-a",
            sessionID: "session-a"
        )

        XCTAssertEqual(
            invocation.get(),
            Invocation(
                brokerURL: Self.primary.absoluteString,
                relayID: "relay-a",
                frontID: "front-a",
                clientID: "client-a",
                sessionID: "session-a"
            )
        )
        XCTAssertEqual(result.ticket, "opaque-ticket")
        XCTAssertEqual(result.url, Self.frontURL)
        XCTAssertEqual(
            result.expiresAt.timeIntervalSince1970,
            Double(expiryMilliseconds) / 1_000,
            accuracy: 0.000_1
        )
        XCTAssertEqual(operation.closeCount, 1)
    }

    func testNativeHTTPStatusAndRetryAfterRemainTyped() async {
        for (status, retryAfter) in [(429, Int64(0)), (503, Int64(7_500))] {
            let operation = TestNativeBrokerOperation()
            operation.ticketHandler = { _, _, _, _, _ in
                NativeBrokerWSSTicketResultSnapshot(
                    succeeded: false,
                    errorKind: status == 429 ? "rate_limited" : "http_status",
                    httpStatus: Int32(status),
                    retryAfterMilliseconds: retryAfter
                )
            }
            do {
                _ = try await WssTicketClient.requestOnce(
                    operationFactory: TestNativeBrokerFactory(operation: operation),
                    brokerURL: Self.primary,
                    relayID: "relay-a",
                    frontID: "front-a"
                )
                XCTFail("expected status \(status)")
            } catch let error as WssTicketStatusError {
                XCTAssertEqual(error.status, status)
                XCTAssertEqual(error.retryAfterMilliseconds, retryAfter > 0 ? UInt64(retryAfter) : nil)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testInvalidExpiryIsLocalDecodeFailure() async {
        let operation = TestNativeBrokerOperation()
        operation.ticketHandler = { _, _, _, _, _ in
            NativeBrokerWSSTicketResultSnapshot(
                succeeded: true,
                ticket: "opaque-ticket",
                url: Self.frontURL,
                expiresAtMilliseconds: -1
            )
        }
        do {
            _ = try await WssTicketClient.requestOnce(
                operationFactory: TestNativeBrokerFactory(operation: operation),
                brokerURL: Self.primary,
                relayID: "relay-a",
                frontID: "front-a"
            )
            XCTFail("expected invalid expiry")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .decode)
            XCTAssertTrue(failure.isLocalPlatformFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSpuriousNativeCancelledAttemptIsTypedFailureAndFailsOverToNextFront() async throws {
        let cancelledOperation = TestNativeBrokerOperation()
        cancelledOperation.ticketHandler = { _, _, _, _, _ in
            NativeBrokerWSSTicketResultSnapshot(
                succeeded: false,
                errorKind: "cancelled",
                errorText: "request cancelled"
            )
        }
        let successOperation = TestNativeBrokerOperation()
        successOperation.ticketHandler = { _, _, _, _, _ in
            NativeBrokerWSSTicketResultSnapshot(
                succeeded: true,
                ticket: "opaque-ticket",
                url: Self.frontURL,
                expiresAtMilliseconds: 1_753_142_520_123
            )
        }
        let factory = TestNativeBrokerFactory([cancelledOperation, successOperation])
        let attempted = TestLockedBox<[String]>([])

        // A native "cancelled" kind with this task still live is one failed attempt, not epoch
        // cancellation: failover must continue to the next front instead of aborting the ladder.
        let ticket = try await WssTicketClient.requestWithFailover(
            brokerURLs: [Self.primary, Self.secondary],
            relayID: "relay-a",
            frontID: "front-a",
            clientID: nil,
            sessionID: nil,
            policy: WssTicketPolicy(),
            monotonicMilliseconds: { 0 },
            wait: { _ in },
            attempt: { brokerURL, relayID, frontID, clientID, sessionID, _ in
                attempted.mutate { $0.append(brokerURL.absoluteString) }
                return try await WssTicketClient.requestOnce(
                    operationFactory: factory,
                    brokerURL: brokerURL,
                    relayID: relayID,
                    frontID: frontID,
                    clientID: clientID,
                    sessionID: sessionID
                )
            }
        )

        XCTAssertEqual(ticket.ticket, "opaque-ticket")
        XCTAssertEqual(
            attempted.get(),
            [Self.primary.absoluteString, Self.secondary.absoluteString]
        )
        XCTAssertEqual(cancelledOperation.closeCount, 1)
        XCTAssertEqual(successOperation.closeCount, 1)
    }

    func testLocalNativeFailureWithIncidentalHTTPStatusIsNotProjectedOrRetried() async {
        let first = TestNativeBrokerOperation()
        first.ticketHandler = { _, _, _, _, _ in
            NativeBrokerWSSTicketResultSnapshot(
                succeeded: false,
                errorKind: "validation",
                httpStatus: 503,
                retryAfterMilliseconds: 1
            )
        }
        let unused = TestNativeBrokerOperation()
        let factory = TestNativeBrokerFactory([first, unused])
        let client = WssTicketClient(operationFactory: factory)

        do {
            _ = try await client.requestWithFailover(
                brokerURLs: [Self.primary, Self.secondary],
                relayID: "relay-a",
                frontID: "front-a"
            )
            XCTFail("expected local validation failure")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .validation)
            XCTAssertEqual(failure.httpStatus, 503)
        } catch {
            XCTFail("local failure was incorrectly projected: \(error)")
        }
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(unused.closeCount, 0)
    }

    func testTicketAndSnapshotDescriptionsRedactTicketAndURL() {
        let ticketSecret = "ticket-secret-7a2f"
        let urlSecret = "wss://secret.example/private"
        let ticket = WssSessionTicket(
            ticket: ticketSecret,
            expiresAt: Date(timeIntervalSince1970: 1_753_142_520),
            url: urlSecret
        )
        let snapshot = NativeBrokerWSSTicketResultSnapshot(
            succeeded: true,
            ticket: ticketSecret,
            url: urlSecret,
            expiresAtMilliseconds: 1_753_142_520_000
        )

        for rendered in [
            String(describing: ticket),
            String(reflecting: ticket),
            String(describing: snapshot),
            String(reflecting: snapshot),
        ] {
            XCTAssertFalse(rendered.contains(ticketSecret), rendered)
            XCTAssertFalse(rendered.contains(urlSecret), rendered)
            XCTAssertTrue(rendered.contains("<redacted>"), rendered)
        }
    }

    func testBrokerFrontFailoverAndBoundedSingleRetryRound() async throws {
        let state = TicketAttemptState()
        let clock = TestLockedBox<UInt64>(0)
        let ticket = successfulTicket()

        let result = try await WssTicketClient.requestWithFailover(
            brokerURLs: [Self.primary, Self.secondary, Self.primary],
            relayID: "relay-a",
            frontID: "front-a",
            clientID: nil,
            sessionID: nil,
            policy: WssTicketPolicy(
                totalDeadlineMilliseconds: 60_000,
                defaultRetryAfterMilliseconds: 10_000,
                maxRetryAfterMilliseconds: 30_000
            ),
            monotonicMilliseconds: { clock.get() },
            wait: { delay in
                state.recordWait(delay)
                clock.mutate { $0 += delay }
            },
            attempt: { broker, _, _, _, _, _ in
                let count = state.recordAttempt(broker)
                if count == 1 {
                    throw WssTicketStatusError(status: 429, retryAfterMilliseconds: nil)
                }
                if count == 2 {
                    throw WssTicketStatusError(status: 503, retryAfterMilliseconds: 120_000)
                }
                return ticket
            }
        )

        XCTAssertEqual(result, ticket)
        XCTAssertEqual(state.attempts, [Self.primary, Self.secondary, Self.primary])
        XCTAssertEqual(state.waits, [30_000])
    }

    func testZeroRetryAfterUsesDefaultDelay() async throws {
        let state = TicketAttemptState()
        let clock = TestLockedBox<UInt64>(0)
        let ticket = successfulTicket()
        _ = try await WssTicketClient.requestWithFailover(
            brokerURLs: [Self.primary],
            relayID: "relay-a",
            frontID: "front-a",
            clientID: nil,
            sessionID: nil,
            policy: WssTicketPolicy(totalDeadlineMilliseconds: 30_000),
            monotonicMilliseconds: { clock.get() },
            wait: { delay in
                state.recordWait(delay)
                clock.mutate { $0 += delay }
            },
            attempt: { broker, _, _, _, _, _ in
                let count = state.recordAttempt(broker)
                if count == 1 {
                    throw WssTicketStatusError(status: 429, retryAfterMilliseconds: 0)
                }
                return ticket
            }
        )
        XCTAssertEqual(state.waits, [10_000])
        XCTAssertEqual(state.attempts, [Self.primary, Self.primary])
    }

    func testNon429Or503NeverSchedulesSecondRoundAndPreservesFirstError() async {
        let state = TicketAttemptState()
        do {
            _ = try await WssTicketClient.requestWithFailover(
                brokerURLs: [Self.primary, Self.secondary, Self.primary],
                relayID: "relay-a",
                frontID: "front-a",
                clientID: nil,
                sessionID: nil,
                policy: WssTicketPolicy(totalDeadlineMilliseconds: 20_000),
                monotonicMilliseconds: { 0 },
                wait: { _ in XCTFail("non-retryable failures must not wait") },
                attempt: { broker, _, _, _, _, _ in
                    _ = state.recordAttempt(broker)
                    throw WssTicketStatusError(
                        status: broker == Self.primary ? 500 : 502,
                        retryAfterMilliseconds: 1
                    )
                }
            )
            XCTFail("expected all fronts to fail")
        } catch let error as WssTicketStatusError {
            XCTAssertEqual(error.status, 500)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(state.attempts, [Self.primary, Self.secondary])
        XCTAssertEqual(state.waits, [])
    }

    func testOneTotalDeadlineShrinksLaterAttemptBudget() async {
        struct Diagnostic: Error {}
        let clock = TestLockedBox<UInt64>(0)
        let timeouts = TestLockedBox<[UInt64]>([])
        do {
            _ = try await WssTicketClient.requestWithFailover(
                brokerURLs: [Self.primary, Self.secondary],
                relayID: "relay-a",
                frontID: "front-a",
                clientID: nil,
                sessionID: nil,
                policy: WssTicketPolicy(
                    totalDeadlineMilliseconds: 7_000,
                    perAttemptMilliseconds: 5_000
                ),
                monotonicMilliseconds: { clock.get() },
                wait: { _ in XCTFail("no retry round expected") },
                attempt: { _, _, _, _, _, timeout in
                    timeouts.mutate { $0.append(timeout) }
                    clock.mutate { $0 += timeout }
                    throw Diagnostic()
                }
            )
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error is Diagnostic)
        }
        XCTAssertEqual(timeouts.get(), [5_000, 2_000])
    }

    func testLocalNativeFailureAbortsBeforeAnotherFront() async {
        let state = TicketAttemptState()
        do {
            _ = try await WssTicketClient.requestWithFailover(
                brokerURLs: [Self.primary, Self.secondary],
                relayID: "relay-a",
                frontID: "front-a",
                clientID: nil,
                sessionID: nil,
                policy: WssTicketPolicy(),
                monotonicMilliseconds: { 0 },
                wait: { _ in },
                attempt: { broker, _, _, _, _, _ in
                    _ = state.recordAttempt(broker)
                    throw BrokerNativeFailure(kind: .unavailable)
                }
            )
            XCTFail("expected local failure")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .unavailable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(state.attempts, [Self.primary])
    }

    func testCallerCancellationClosesCurrentAttemptAndNeverAdvancesFront() async {
        let blocked = BlockingNativeBrokerOperation()
        let unused = TestNativeBrokerOperation()
        let factory = TestNativeBrokerFactory([blocked, unused])
        let client = WssTicketClient(operationFactory: factory)
        let task = Task {
            try await client.requestWithFailover(
                brokerURLs: [Self.primary, Self.secondary],
                relayID: "relay-a",
                frontID: "front-a"
            )
        }
        XCTAssertTrue(blocked.waitUntilStarted())
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertGreaterThanOrEqual(blocked.closeCount, 1)
        XCTAssertEqual(unused.closeCount, 0)
    }

    func testTicketFreshnessIsRecheckedAtNativeDialBoundary() {
        let expiry = Date(timeIntervalSince1970: 1_753_142_400)
        let ticket = WssSessionTicket(ticket: "opaque", expiresAt: expiry, url: Self.frontURL)
        XCTAssertTrue(ticket.isFresh(at: expiry.addingTimeInterval(-0.001)))
        XCTAssertFalse(ticket.isFresh(at: expiry))
        XCTAssertFalse(ticket.isFresh(at: expiry.addingTimeInterval(1)))
    }

    private func successfulTicket() -> WssSessionTicket {
        WssSessionTicket(
            ticket: "ticket",
            expiresAt: Date.distantFuture,
            url: Self.frontURL
        )
    }
}

private final class TicketAttemptState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttempts: [URL] = []
    private var storedWaits: [UInt64] = []

    @discardableResult
    func recordAttempt(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedAttempts.append(url)
        return storedAttempts.count
    }

    func recordWait(_ delay: UInt64) {
        lock.lock()
        storedWaits.append(delay)
        lock.unlock()
    }

    var attempts: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storedAttempts
    }

    var waits: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return storedWaits
    }
}
