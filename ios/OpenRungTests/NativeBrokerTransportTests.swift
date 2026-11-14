import Foundation
import XCTest

final class NativeBrokerTransportTests: XCTestCase {
    func testCancellationBeforeWorkerStartClosesAndThrowsCancellation() async {
        let gate = TestAsyncGate()
        let operation = TestNativeBrokerOperation()
        let invocationCount = TestLockedBox(0)
        let closed = expectation(description: "pre-cancelled operation closes")
        closed.assertForOverFulfill = false
        operation.manifestHandler = { _ in
            invocationCount.mutate { $0 += 1 }
            return NativeBrokerManifestResultSnapshot(succeeded: true)
        }
        operation.closeHandler = {
            closed.fulfill()
        }
        let task = Task {
            await gate.wait()
            let _: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.fetchManifestCandidate(candidateURL: "https://broker.example/")
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
        operation.manifestHandler = { _ in
            invocationCount.mutate { $0 += 1 }
            return NativeBrokerManifestResultSnapshot(succeeded: true)
        }
        operation.closeHandler = {
            closed.fulfill()
        }

        let task = Task {
            let _: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.runForTesting(
                factory: TestNativeBrokerFactory(operation: operation),
                beforeWorkerStart: {
                    await reachedPrestartWindow.open()
                    await releaseWorker.wait()
                }
            ) {
                $0.fetchManifestCandidate(candidateURL: "https://broker.example/")
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
            let _: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.fetchManifestCandidate(candidateURL: "https://broker.example/")
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
            let result: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: operation)
            ) {
                $0.fetchManifestCandidate(candidateURL: "https://broker.example/")
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
        independentOperation.manifestHandler = { _ in
            NativeBrokerManifestResultSnapshot(succeeded: true)
        }

        let cancelledTask = Task {
            let _: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
                factory: TestNativeBrokerFactory(operation: cancelledOperation)
            ) {
                $0.fetchManifestCandidate(candidateURL: "https://one.example/")
            }
        }
        XCTAssertTrue(cancelledOperation.waitUntilStarted())

        let independent: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
            factory: TestNativeBrokerFactory(operation: independentOperation)
        ) {
            $0.fetchManifestCandidate(candidateURL: "https://two.example/")
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
        nilResultOperation.manifestHandler = { _ in nil }
        for factory in [
            TestNativeBrokerFactory(operation: nilResultOperation),
            TestNativeBrokerFactory(operation: nil),
        ] {
            do {
                let _: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(factory: factory) {
                    $0.fetchManifestCandidate(candidateURL: "https://broker.example/")
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
        // No cancelled task exists here: a native "cancelled" kind reaching a live caller is a
        // bounded typed failure, never cooperative cancellation minted on the binding's behalf.
        let cancelled = NativeBrokerManifestResultSnapshot(succeeded: false, errorKind: "cancelled")
        XCTAssertThrowsError(try cancelled.throwIfFailed()) { error in
            guard let failure = error as? BrokerNativeFailure else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(failure.kind, .cancelled)
            XCTAssertFalse(failure.isLocalPlatformFailure)
        }

        for bindingKind in ["", "future_kind", "unavailable", "decode"] {
            let future = NativeBrokerManifestResultSnapshot(
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

    func testBindingCancellationInCancelledTaskRemainsCooperativeCancellation() async {
        let snapshot = NativeBrokerManifestResultSnapshot(succeeded: false, errorKind: "cancelled")
        let task = Task.detached { () -> Error? in
            while Task.isCancelled == false {
                await Task.yield()
            }
            do {
                try snapshot.throwIfFailed()
                return nil
            } catch {
                return error
            }
        }
        task.cancel()

        let observed = await task.value
        XCTAssertTrue(
            observed is CancellationError,
            "got \(String(describing: observed))"
        )
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

    func testManifestSnapshotsPreserveEveryGeneratedField() {
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

    func fetchManifestCandidate(
        candidateURL _: String
    ) -> NativeBrokerManifestResultSnapshot? {
        NativeBrokerManifestResultSnapshot(
            succeeded: true,
            bodyJSON: "{}",
            sourceURL: "https://broker.openrung.org/api/v1/app-manifest"
        )
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
