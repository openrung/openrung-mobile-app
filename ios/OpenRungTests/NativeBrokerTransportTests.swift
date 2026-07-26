import Foundation
import XCTest

final class NativeBrokerTransportTests: XCTestCase {
    func testCancellationBeforeWorkerStartClosesAndThrowsCancellation() async {
        let gate = TestAsyncGate()
        let operation = TestNativeBrokerOperation()
        let invocationCount = TestLockedBox(0)
        let closed = expectation(description: "pre-cancelled operation closes")
        closed.assertForOverFulfill = false
        operation.telemetryHandler = { _, _ in
            invocationCount.mutate { $0 += 1 }
            return NativeBrokerResultSnapshot(succeeded: true)
        }
        operation.closeHandler = {
            closed.fulfill()
        }
        let task = Task {
            await gate.wait()
            let _: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.sendTelemetryBatchJSON(brokerURL: "https://broker.example/", batchJSON: "{}")
            }
        }

        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertEqual(invocationCount.get(), 0, "a pre-cancelled task must not start native work")
        XCTAssertGreaterThanOrEqual(operation.closeCount, 1)
    }

    func testCancellationAfterPrecheckButBeforeWorkerClaimNeverInvokesNativeSelector() async {
        let reachedPrestartWindow = TestAsyncGate()
        let releaseWorker = TestAsyncGate()
        let operation = TestNativeBrokerOperation()
        let invocationCount = TestLockedBox(0)
        let closed = expectation(description: "operation closes after winning prestart cancellation")
        closed.assertForOverFulfill = false
        operation.telemetryHandler = { _, _ in
            invocationCount.mutate { $0 += 1 }
            return NativeBrokerResultSnapshot(succeeded: true)
        }
        operation.closeHandler = {
            closed.fulfill()
        }

        let task = Task {
            let _: NativeBrokerResultSnapshot = try await NativeBrokerRunner.runForTesting(
                factory: TestNativeBrokerFactory(operation: operation),
                beforeWorkerStart: {
                    await reachedPrestartWindow.open()
                    await releaseWorker.wait()
                }
            ) {
                $0.sendTelemetryBatchJSON(brokerURL: "https://broker.example/", batchJSON: "{}")
            }
        }

        await reachedPrestartWindow.wait()
        task.cancel()
        await releaseWorker.open()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        await fulfillment(of: [closed], timeout: 1)
        XCTAssertEqual(invocationCount.get(), 0)
        XCTAssertGreaterThanOrEqual(operation.closeCount, 1)
    }

    func testCancellationDuringBlockedCallClosesAndUnblocksPromptly() async {
        let operation = BlockingNativeBrokerOperation()
        let task = Task {
            let _: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.sendTelemetryBatchJSON(brokerURL: "https://broker.example/", batchJSON: "{}")
            }
        }
        XCTAssertTrue(operation.waitUntilStarted())

        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 1)
        XCTAssertGreaterThanOrEqual(operation.closeCount, 1)
    }

    func testSuccessRacingWithCancellationCannotCommitAndConcurrentCloseIsSafe() async {
        let operation = CloseGatedSuccessOperation()
        let task = Task {
            let result: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.sendTelemetryBatchJSON(brokerURL: "https://broker.example/", batchJSON: "{}")
            }
            return result.succeeded
        }
        XCTAssertTrue(operation.waitUntilCloseStarted())

        task.cancel()
        XCTAssertTrue(operation.waitUntilCloseCount(2))
        operation.releaseClose()
        do {
            _ = try await task.value
            XCTFail("a success racing with cancellation must not commit")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertGreaterThanOrEqual(operation.closeCount, 2)
    }

    func testCancellingOneOperationDoesNotCancelAnother() async throws {
        let cancelledOperation = BlockingNativeBrokerOperation()
        let independentOperation = TestNativeBrokerOperation()
        independentOperation.telemetryHandler = { _, _ in
            NativeBrokerResultSnapshot(succeeded: true)
        }

        let cancelledTask = Task {
            let _: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: cancelledOperation)
            ) {
                $0.sendTelemetryBatchJSON(brokerURL: "https://one.example/", batchJSON: "{}")
            }
        }
        XCTAssertTrue(cancelledOperation.waitUntilStarted())

        let independent: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
            factory: TestNativeBrokerFactory(operation: independentOperation)
        ) {
            $0.sendTelemetryBatchJSON(brokerURL: "https://two.example/", batchJSON: "{}")
        }
        XCTAssertTrue(independent.succeeded)
        XCTAssertEqual(independentOperation.closeCount, 1)

        cancelledTask.cancel()
        do {
            _ = try await cancelledTask.value
            XCTFail("expected first operation cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testNilResultAndNilFactoryAreUnavailable() async {
        let nilResultOperation = TestNativeBrokerOperation()
        nilResultOperation.telemetryHandler = { _, _ in nil }
        for factory in [
            TestNativeBrokerFactory(operation: nilResultOperation),
            TestNativeBrokerFactory(operation: nil),
        ] {
            do {
                let _: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(factory: factory) {
                    $0.sendTelemetryBatchJSON(brokerURL: "https://broker.example/", batchJSON: "{}")
                }
                XCTFail("expected unavailable")
            } catch let failure as BrokerNativeFailure {
                XCTAssertEqual(failure.kind, .unavailable)
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testBindingCancellationAndFutureKindsAreNormalized() {
        let cancelled = NativeBrokerResultSnapshot(succeeded: false, errorKind: "cancelled")
        XCTAssertThrowsError(try cancelled.throwIfFailed()) { error in
            XCTAssertTrue(error is CancellationError)
        }

        for bindingKind in ["", "future_kind", "unavailable", "decode"] {
            let future = NativeBrokerResultSnapshot(
                succeeded: false,
                errorKind: bindingKind,
                errorText: "line one\nline two\u{0000}" + String(repeating: "x", count: 400)
            )
            XCTAssertThrowsError(try future.throwIfFailed()) { error in
                guard let failure = error as? BrokerNativeFailure else {
                    return XCTFail("unexpected error: \(error)")
                }
                XCTAssertEqual(failure.kind, .unknown)
                XCTAssertFalse(failure.message.contains("\n"))
                XCTAssertLessThanOrEqual(failure.message.utf8.count, 256)
            }
        }
    }
}

private actor TestAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let ready = waiters
        waiters.removeAll()
        ready.forEach { $0.resume() }
    }
}

/// Returns a successful snapshot, then blocks its worker-finally `close()`. Cancelling while that
/// close is blocked exercises the runner's concurrent on-cancel close and post-worker check.
final class CloseGatedSuccessOperation: NativeBrokerOperation, @unchecked Sendable {
    private let condition = NSCondition()
    private var closeStarted = false
    private var closeReleased = false
    private var storedCloseCount = 0

    func firstReachable(
        primary _: String,
        limit _: Int32,
        clientID _: String,
        sessionID _: String
    ) -> NativeBrokerRelayResultSnapshot? {
        NativeBrokerRelayResultSnapshot(succeeded: true)
    }

    func sendTelemetryBatchJSON(
        brokerURL _: String,
        batchJSON _: String
    ) -> NativeBrokerResultSnapshot? {
        NativeBrokerResultSnapshot(succeeded: true)
    }

    func requestWSSTicket(
        brokerURL _: String,
        relayID _: String,
        frontID _: String,
        clientID _: String,
        sessionID _: String
    ) -> NativeBrokerWSSTicketResultSnapshot? {
        NativeBrokerWSSTicketResultSnapshot(succeeded: true)
    }

    func close() {
        condition.lock()
        storedCloseCount += 1
        closeStarted = true
        condition.broadcast()
        while closeReleased == false {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilCloseStarted(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while closeStarted == false, condition.wait(until: deadline) {
            // Re-check under the condition lock.
        }
        return closeStarted
    }

    func releaseClose() {
        condition.lock()
        closeReleased = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilCloseCount(_ count: Int, timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while storedCloseCount < count, condition.wait(until: deadline) {
            // Re-check under the condition lock.
        }
        return storedCloseCount >= count
    }

    var closeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedCloseCount
    }
}
