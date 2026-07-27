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

    func testConfiguredFactoriesSelectNativeAndReactNativeConstructors() {
        let iosOperation = TestNativeBrokerOperation()
        let reactNativeOperation = TestNativeBrokerOperation()
        let constructor = TestNativeBrokerConstructor(
            iosOperation: iosOperation,
            reactNativeOperation: reactNativeOperation
        )

        let iosFactory = ConfiguredNativeBrokerOperationFactory(
            appVersion: "1.2.3",
            client: .ios(osVersion: "18.5"),
            constructor: constructor
        )
        let reactNativeFactory = ConfiguredNativeBrokerOperationFactory.forReactNativeIOS(
            appVersion: "1.2.3",
            constructor: constructor
        )

        XCTAssertTrue(iosFactory.makeOperation() === iosOperation)
        XCTAssertTrue(reactNativeFactory.makeOperation() === reactNativeOperation)
        XCTAssertEqual(
            constructor.calls,
            [
                .ios(appVersion: "1.2.3", osVersion: "18.5"),
                .reactNative(appVersion: "1.2.3", osToken: "ios"),
            ]
        )
    }

    func testSpeedAndManifestSnapshotsPreserveEveryGeneratedField() {
        let speed = NativeBrokerSpeedTestResultSnapshot(
            succeeded: true,
            errorKind: "",
            errorText: "",
            httpStatus: 201,
            retryAfterMilliseconds: 2_000,
            bytes: 10_000_000,
            timeToFirstByteMilliseconds: 125,
            downloadDurationMilliseconds: 2_000,
            totalDurationMilliseconds: 2_125,
            megabitsPerSecond: 37.647
        )
        XCTAssertEqual(speed.bytes, 10_000_000)
        XCTAssertEqual(speed.timeToFirstByteMilliseconds, 125)
        XCTAssertEqual(speed.downloadDurationMilliseconds, 2_000)
        XCTAssertEqual(speed.totalDurationMilliseconds, 2_125)
        XCTAssertEqual(speed.megabitsPerSecond, 37.647)
        XCTAssertEqual(speed.httpStatus, 201)
        XCTAssertEqual(speed.retryAfterMilliseconds, 2_000)

        let manifest = NativeBrokerManifestResultSnapshot(
            succeeded: true,
            bodyJSON: "{\"signed\":\"exact bytes\"}",
            sourceURL: "https://broker.openrung.org/api/v1/app-manifest"
        )
        XCTAssertEqual(manifest.bodyJSON, "{\"signed\":\"exact bytes\"}")
        XCTAssertEqual(
            manifest.sourceURL,
            "https://broker.openrung.org/api/v1/app-manifest"
        )
        XCTAssertFalse(manifest.description.contains("exact bytes"))
        XCTAssertTrue(manifest.description.contains("bodyJSON: <redacted>"))
    }

    func testRelaySnapshotDescriptionsRedactRawDirectoryAndURLs() {
        let secretURL = "wss://secret-front.example/credential-path"
        let relay = NativeBrokerRelayResultSnapshot(
            succeeded: true,
            brokerURL: "https://broker.openrung.org",
            relayJSON: """
            {"relays":[{"id":"relay-1","wss_fronts":["\(secretURL)"]}]}
            """,
            keyID: "directory-key",
            signatureVerified: true
        )

        XCTAssertFalse(String(describing: relay).contains(secretURL))
        XCTAssertFalse(String(reflecting: relay).contains(secretURL))
        XCTAssertFalse(String(describing: relay).contains("broker.openrung.org"))
        XCTAssertTrue(relay.description.contains("relayJSON: <redacted>"))
        XCTAssertTrue(relay.debugDescription.contains("brokerURL: <redacted>"))
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

    func runSpeedTest(
        brokerURL _: String
    ) -> NativeBrokerSpeedTestResultSnapshot? {
        NativeBrokerSpeedTestResultSnapshot(
            succeeded: true,
            bytes: 1,
            megabitsPerSecond: 1
        )
    }

    func fetchManifestCandidate(
        candidateURL _: String
    ) -> NativeBrokerManifestResultSnapshot? {
        NativeBrokerManifestResultSnapshot(
            succeeded: true,
            bodyJSON: "{}",
            sourceURL: "https://broker.openrung.org/api/v1/app-manifest"
        )
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

private final class TestNativeBrokerConstructor:
    NativeBrokerOperationConstructing,
    @unchecked Sendable
{
    enum Call: Equatable {
        case ios(appVersion: String, osVersion: String)
        case reactNative(appVersion: String, osToken: String)
    }

    private let lock = NSLock()
    private let iosOperation: any NativeBrokerOperation
    private let reactNativeOperation: any NativeBrokerOperation
    private var storedCalls: [Call] = []

    init(
        iosOperation: any NativeBrokerOperation,
        reactNativeOperation: any NativeBrokerOperation
    ) {
        self.iosOperation = iosOperation
        self.reactNativeOperation = reactNativeOperation
    }

    func makeIOSOperation(
        appVersion: String,
        osVersion: String
    ) -> (any NativeBrokerOperation)? {
        lock.lock()
        storedCalls.append(.ios(appVersion: appVersion, osVersion: osVersion))
        lock.unlock()
        return iosOperation
    }

    func makeReactNativeOperation(
        appVersion: String,
        osToken: String
    ) -> (any NativeBrokerOperation)? {
        lock.lock()
        storedCalls.append(.reactNative(appVersion: appVersion, osToken: osToken))
        lock.unlock()
        return reactNativeOperation
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }
}
