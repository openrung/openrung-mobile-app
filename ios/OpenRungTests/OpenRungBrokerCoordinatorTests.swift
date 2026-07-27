import Foundation
import XCTest

final class OpenRungBrokerCoordinatorTests: XCTestCase {
    func testFirstReachableRequiresPositiveLimitAndForwardsVerificationMetadata() async {
        let operation = TestNativeBrokerOperation()
        let receivedLimit = TestLockedBox<Int32?>(nil)
        operation.relayHandler = { _, limit, _, _ in
            receivedLimit.set(limit)
            return NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: "http://127.0.0.1:8080/",
                relayJSON: "{\"relays\":[]}",
                keyID: "dev",
                signatureVerified: false
            )
        }
        let factory = TestNativeBrokerFactory(operation: operation)
        let coordinator = OpenRungBrokerRequestCoordinator(operationFactory: factory)

        let forwardedVerification = TestLockedBox<Bool?>(nil)
        let succeeded = expectation(description: "relay result")
        coordinator.firstReachable(
            requestID: "relay",
            primary: "http://127.0.0.1:8080/",
            limit: 5,
            clientID: "client",
            sessionID: "session"
        ) { result in
            if case .success(let snapshot) = result {
                forwardedVerification.set(snapshot.signatureVerified)
            }
            succeeded.fulfill()
        }
        await fulfillment(of: [succeeded], timeout: 2)
        XCTAssertEqual(receivedLimit.get(), 5)
        XCTAssertEqual(forwardedVerification.get(), false)
        XCTAssertEqual(factory.makeCount, 1)

        let invalidKind = TestLockedBox<BrokerNativeFailureKind?>(nil)
        let invalidFinished = expectation(description: "invalid limit")
        coordinator.firstReachable(
            requestID: "invalid-limit",
            primary: "https://broker.openrung.org/",
            limit: 0,
            clientID: "client",
            sessionID: "session"
        ) { result in
            if case .failure(let failure) = result {
                invalidKind.set(failure.kind)
            }
            invalidFinished.fulfill()
        }
        await fulfillment(of: [invalidFinished], timeout: 1)
        XCTAssertEqual(invalidKind.get(), .validation)
        XCTAssertEqual(factory.makeCount, 1, "invalid limits must not mint an operation")
    }

    func testFirstReachableRemovesWSSFrontsAndRejectsMalformedJSON() async throws {
        let secretURL = "wss://secret-front.example/credential-path"
        let validOperation = TestNativeBrokerOperation()
        validOperation.relayHandler = { _, _, _, _ in
            NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: "https://broker.openrung.org/",
                relayJSON: """
                {
                  "count": 1,
                  "server_time": "2026-07-26T00:00:00Z",
                  "channel": "api",
                  "relays": [{
                    "id": "relay-a",
                    "label": "Keep this directory field",
                    "wss_fronts": [{
                      "id": "front-a",
                      "url": "\(secretURL)",
                      "protocol_version": 1
                    }]
                  }]
                }
                """
            )
        }
        let malformedOperation = TestNativeBrokerOperation()
        malformedOperation.relayHandler = { _, _, _, _ in
            NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: "https://broker.openrung.org/",
                relayJSON: #"{"relays":["#
            )
        }
        let coordinator = OpenRungBrokerRequestCoordinator(
            operationFactory: TestNativeBrokerFactory([
                validOperation,
                malformedOperation,
            ])
        )

        let projectedJSON = TestLockedBox<String?>(nil)
        let projected = expectation(description: "relay projection")
        coordinator.firstReachable(
            requestID: "projected",
            primary: "https://broker.openrung.org/",
            limit: 5,
            clientID: "client",
            sessionID: "session"
        ) { result in
            if case .success(let snapshot) = result {
                projectedJSON.set(snapshot.relayJSON)
            }
            projected.fulfill()
        }
        await fulfillment(of: [projected], timeout: 1)

        let json = try XCTUnwrap(projectedJSON.get())
        XCTAssertFalse(json.contains("wss_fronts"))
        XCTAssertFalse(json.contains(secretURL))
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertEqual(root["channel"] as? String, "api")
        let relays = try XCTUnwrap(root["relays"] as? [[String: Any]])
        XCTAssertEqual(relays.first?["id"] as? String, "relay-a")
        XCTAssertEqual(relays.first?["label"] as? String, "Keep this directory field")
        XCTAssertNil(relays.first?["wss_fronts"])

        let malformedFailure = TestLockedBox<BrokerNativeFailure?>(nil)
        let malformed = expectation(description: "malformed relay JSON")
        coordinator.firstReachable(
            requestID: "malformed",
            primary: "https://broker.openrung.org/",
            limit: 5,
            clientID: "client",
            sessionID: "session"
        ) { result in
            if case .failure(let failure) = result {
                malformedFailure.set(failure)
            }
            malformed.fulfill()
        }
        await fulfillment(of: [malformed], timeout: 1)

        XCTAssertEqual(malformedFailure.get()?.kind, .decode)
        XCTAssertEqual(
            malformedFailure.get()?.message,
            "The native relay directory could not be decoded."
        )
        XCTAssertFalse(malformedFailure.get()?.message.contains("relays") == true)
        XCTAssertEqual(validOperation.closeCount, 1)
        XCTAssertEqual(malformedOperation.closeCount, 1)
    }

    func testSpeedAndManifestResultsAreForwardedAsPlatformSnapshots() async {
        let speedOperation = TestNativeBrokerOperation()
        let manifestOperation = TestNativeBrokerOperation()
        let speedURL = TestLockedBox("")
        let manifestURL = TestLockedBox("")
        speedOperation.speedTestHandler = { brokerURL in
            speedURL.set(brokerURL)
            return NativeBrokerSpeedTestResultSnapshot(
                succeeded: true,
                bytes: 10_000_000,
                timeToFirstByteMilliseconds: 125,
                downloadDurationMilliseconds: 2_000,
                totalDurationMilliseconds: 2_125,
                megabitsPerSecond: 37.647
            )
        }
        manifestOperation.manifestHandler = { candidateURL in
            manifestURL.set(candidateURL)
            return NativeBrokerManifestResultSnapshot(
                succeeded: true,
                bodyJSON: "{\"signed\":\"exact bytes\"}",
                sourceURL: candidateURL
            )
        }
        let coordinator = OpenRungBrokerRequestCoordinator(
            operationFactory: TestNativeBrokerFactory([
                speedOperation,
                manifestOperation,
            ])
        )

        let speedResult = TestLockedBox<NativeBrokerSpeedTestResultSnapshot?>(nil)
        let speedFinished = expectation(description: "speed result")
        coordinator.runSpeedTest(
            requestID: "speed-1",
            brokerURL: "https://broker.openrung.org/"
        ) { result in
            if case .success(let snapshot) = result {
                speedResult.set(snapshot)
            }
            speedFinished.fulfill()
        }
        await fulfillment(of: [speedFinished], timeout: 2)

        XCTAssertEqual(speedURL.get(), "https://broker.openrung.org/")
        XCTAssertEqual(speedResult.get()?.bytes, 10_000_000)
        XCTAssertEqual(speedResult.get()?.timeToFirstByteMilliseconds, 125)
        XCTAssertEqual(speedResult.get()?.downloadDurationMilliseconds, 2_000)
        XCTAssertEqual(speedResult.get()?.totalDurationMilliseconds, 2_125)
        XCTAssertEqual(speedResult.get()?.megabitsPerSecond, 37.647)
        XCTAssertEqual(speedOperation.closeCount, 1)

        let candidateURL = "https://broker.openrung.org/api/v1/app-manifest"
        let manifestResult = TestLockedBox<NativeBrokerManifestResultSnapshot?>(nil)
        let manifestFinished = expectation(description: "manifest result")
        coordinator.fetchManifestCandidate(
            requestID: "manifest-1",
            candidateURL: candidateURL
        ) { result in
            if case .success(let snapshot) = result {
                manifestResult.set(snapshot)
            }
            manifestFinished.fulfill()
        }
        await fulfillment(of: [manifestFinished], timeout: 2)

        XCTAssertEqual(manifestURL.get(), candidateURL)
        XCTAssertEqual(manifestResult.get()?.bodyJSON, "{\"signed\":\"exact bytes\"}")
        XCTAssertEqual(manifestResult.get()?.sourceURL, candidateURL)
        XCTAssertEqual(manifestOperation.closeCount, 1)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 0)
    }

    func testDuplicateActiveRequestIsRejectedWithoutCreatingAnotherOperation() async {
        let operation = BlockingNativeBrokerOperation()
        let factory = TestNativeBrokerFactory(operation: operation)
        let coordinator = OpenRungBrokerRequestCoordinator(operationFactory: factory)
        let firstFailure = TestLockedBox<BrokerNativeFailureKind?>(nil)
        let firstFinished = expectation(description: "first request cancelled")
        coordinator.sendTelemetryBatchJSON(
            requestID: "duplicate",
            brokerURL: "https://broker.openrung.org/",
            batchJSON: "{\"events\":[{}]}"
        ) { result in
            if case .failure(let failure) = result {
                firstFailure.set(failure.kind)
            }
            firstFinished.fulfill()
        }
        XCTAssertTrue(operation.waitUntilStarted())

        let duplicateFailure = TestLockedBox<BrokerNativeFailureKind?>(nil)
        let duplicateFinished = expectation(description: "duplicate rejected")
        coordinator.runSpeedTest(
            requestID: "duplicate",
            brokerURL: "https://broker.openrung.org/"
        ) { result in
            if case .failure(let failure) = result {
                duplicateFailure.set(failure.kind)
            }
            duplicateFinished.fulfill()
        }
        await fulfillment(of: [duplicateFinished], timeout: 1)

        XCTAssertEqual(duplicateFailure.get(), .validation)
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 1)
        XCTAssertTrue(coordinator.cancel(requestID: "duplicate"))
        XCTAssertTrue(coordinator.cancel(requestID: "duplicate"), "repeat cancel is idempotent")
        await fulfillment(of: [firstFinished], timeout: 2)
        XCTAssertEqual(firstFailure.get(), .cancelled)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 0)
        XCTAssertFalse(coordinator.cancel(requestID: "duplicate"))
        XCTAssertGreaterThanOrEqual(operation.closeCount, 1)
    }

    func testMissingNativeOperationReportsUnavailableAndRequiresRebuild() async {
        let coordinator = OpenRungBrokerRequestCoordinator(
            operationFactory: TestNativeBrokerFactory(operation: nil)
        )
        let receivedFailure = TestLockedBox<BrokerNativeFailure?>(nil)
        let finished = expectation(description: "unavailable native operation")

        coordinator.runSpeedTest(
            requestID: "unavailable",
            brokerURL: "https://broker.openrung.org/"
        ) { result in
            if case .failure(let failure) = result {
                receivedFailure.set(failure)
            }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 1)

        XCTAssertEqual(receivedFailure.get()?.kind, .unavailable)
        XCTAssertEqual(
            receivedFailure.get()?.message,
            "The native broker transport is unavailable; rebuild the app."
        )
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 0)
    }

    func testSuccessRacingCancellationIsDeliveredOnlyAsCancelled() async {
        let operation = CloseGatedSuccessOperation()
        let coordinator = OpenRungBrokerRequestCoordinator(
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )
        let completionKind = TestLockedBox<BrokerNativeFailureKind?>(nil)
        let finished = expectation(description: "cancelled result")
        coordinator.runSpeedTest(
            requestID: "race",
            brokerURL: "https://broker.openrung.org/"
        ) { result in
            if case .failure(let failure) = result {
                completionKind.set(failure.kind)
            }
            finished.fulfill()
        }
        XCTAssertTrue(operation.waitUntilCloseStarted())

        XCTAssertTrue(coordinator.cancel(requestID: "race"))
        XCTAssertTrue(operation.waitUntilCloseCount(2))
        operation.releaseClose()
        await fulfillment(of: [finished], timeout: 2)

        XCTAssertEqual(completionKind.get(), .cancelled)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 0)
    }

    func testInvalidationCancelsAllAndRejectsNewWork() async {
        let first = BlockingNativeBrokerOperation()
        let second = BlockingNativeBrokerOperation()
        let factory = TestNativeBrokerFactory([first, second])
        let coordinator = OpenRungBrokerRequestCoordinator(operationFactory: factory)
        let deliveredCompletions = TestLockedBox(0)

        coordinator.sendTelemetryBatchJSON(
            requestID: "one",
            brokerURL: "https://broker.openrung.org/",
            batchJSON: "{\"events\":[{}]}"
        ) { _ in
            deliveredCompletions.mutate { $0 += 1 }
        }
        XCTAssertTrue(first.waitUntilStarted())
        coordinator.runSpeedTest(
            requestID: "two",
            brokerURL: "https://broker.openrung.org/"
        ) { _ in
            deliveredCompletions.mutate { $0 += 1 }
        }
        XCTAssertTrue(second.waitUntilStarted())

        coordinator.invalidate()
        coordinator.invalidate()
        XCTAssertTrue(first.waitUntilClosed())
        XCTAssertTrue(second.waitUntilClosed())
        let becameIdle = await waitUntil {
            coordinator.activeRequestCountForTesting == 0
        }
        XCTAssertTrue(becameIdle)
        XCTAssertEqual(deliveredCompletions.get(), 0)

        let rejectedKind = TestLockedBox<BrokerNativeFailureKind?>(nil)
        let rejected = expectation(description: "work after invalidation rejected")
        coordinator.fetchManifestCandidate(
            requestID: "three",
            candidateURL: "https://broker.openrung.org/api/v1/app-manifest"
        ) { result in
            if case .failure(let failure) = result {
                rejectedKind.set(failure.kind)
            }
            rejected.fulfill()
        }
        await fulfillment(of: [rejected], timeout: 1)
        XCTAssertEqual(rejectedKind.get(), .unavailable)
        XCTAssertEqual(factory.makeCount, 2)
    }

    func testDeinitCancelsBlockedOperationWithoutRetainCycle() async {
        let operation = BlockingNativeBrokerOperation()
        let deliveredCompletions = TestLockedBox(0)
        var coordinator: OpenRungBrokerRequestCoordinator? =
            OpenRungBrokerRequestCoordinator(
                operationFactory: TestNativeBrokerFactory(operation: operation)
            )
        weak var weakCoordinator = coordinator

        coordinator?.sendTelemetryBatchJSON(
            requestID: "deinit",
            brokerURL: "https://broker.openrung.org/",
            batchJSON: "{\"events\":[{}]}"
        ) { _ in
            deliveredCompletions.mutate { $0 += 1 }
        }
        XCTAssertTrue(operation.waitUntilStarted())

        coordinator = nil
        XCTAssertNil(weakCoordinator)
        XCTAssertTrue(operation.waitUntilClosed())
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(deliveredCompletions.get(), 0)
    }

    func testCancellingOneRequestDoesNotAffectConcurrentRequest() async {
        let blocked = BlockingNativeBrokerOperation()
        let independent = TestNativeBrokerOperation()
        independent.manifestHandler = { candidateURL in
            NativeBrokerManifestResultSnapshot(
                succeeded: true,
                bodyJSON: "{}",
                sourceURL: candidateURL
            )
        }
        let factory = TestNativeBrokerFactory([blocked, independent])
        let coordinator = OpenRungBrokerRequestCoordinator(operationFactory: factory)

        let blockedFinished = expectation(description: "blocked request cancelled")
        coordinator.runSpeedTest(
            requestID: "blocked",
            brokerURL: "https://broker.openrung.org/"
        ) { _ in
            blockedFinished.fulfill()
        }
        XCTAssertTrue(blocked.waitUntilStarted())

        let independentSucceeded = TestLockedBox(false)
        let independentFinished = expectation(description: "independent request succeeds")
        coordinator.fetchManifestCandidate(
            requestID: "independent",
            candidateURL: "https://broker.openrung.org/api/v1/app-manifest"
        ) { result in
            if case .success = result {
                independentSucceeded.set(true)
            }
            independentFinished.fulfill()
        }
        await fulfillment(of: [independentFinished], timeout: 2)

        XCTAssertTrue(independentSucceeded.get())
        XCTAssertEqual(independent.closeCount, 1)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 1)
        XCTAssertTrue(coordinator.cancel(requestID: "blocked"))
        await fulfillment(of: [blockedFinished], timeout: 2)
        XCTAssertEqual(coordinator.activeRequestCountForTesting, 0)
        XCTAssertEqual(factory.makeCount, 2)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @escaping () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false {
            if Date() >= deadline {
                return false
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}
