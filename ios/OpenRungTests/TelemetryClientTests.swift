import Foundation
import XCTest

final class TelemetryClientTests: XCTestCase {
    private let brokerURL = URL(string: "https://telemetry.example/base/")!

    func testEmptyBatchDoesNotCreateAnOperationOrCommit() async throws {
        let factory = TestNativeBrokerFactory(operation: nil)
        let committed = TestLockedBox(false)
        let client = TelemetryClient(brokerURL: brokerURL, operationFactory: factory)

        try await client.sendAndCommit([]) {
            committed.set(true)
        }

        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertFalse(committed.get())
    }

    func testSendsExactEncodedBatchJSONAndBrokerURL() async throws {
        let capture = TestLockedBox<(brokerURL: String, batchJSON: String)?>(nil)
        let operation = TestNativeBrokerOperation()
        operation.telemetryHandler = { brokerURL, batchJSON in
            capture.set((brokerURL, batchJSON))
            return NativeBrokerResultSnapshot(succeeded: true)
        }
        let event = makeEvent()
        let client = TelemetryClient(
            brokerURL: brokerURL,
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )

        try await client.send([event])

        XCTAssertEqual(capture.get()?.brokerURL, brokerURL.absoluteString)
        XCTAssertEqual(
            capture.get()?.batchJSON,
            #"{"events":[{"attributes":{},"client_id":"client-a","event":"session_heartbeat","event_id":"event-a","measurements":{},"occurred_at":"2026-07-26T00:00:00Z","schema_version":1,"session_id":"session-a"}]}"#
        )
        XCTAssertEqual(operation.closeCount, 1)
    }

    func testFailedSendDoesNotCommitQueuedIDs() async {
        let operation = TestNativeBrokerOperation()
        operation.telemetryHandler = { _, _ in
            NativeBrokerResultSnapshot(
                succeeded: false,
                errorKind: "network",
                errorText: "network unavailable"
            )
        }
        let removedIDs = TestLockedBox<Set<String>>([])
        let client = TelemetryClient(
            brokerURL: brokerURL,
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )

        do {
            try await client.sendAndCommit([makeEvent()]) {
                removedIDs.set(["event-a"])
            }
            XCTFail("expected native failure")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .network)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(removedIDs.get(), [])
    }

    func testCancelledSendClosesAndDoesNotCommitQueuedIDs() async {
        let operation = BlockingNativeBrokerOperation()
        let removedIDs = TestLockedBox<Set<String>>([])
        let client = TelemetryClient(
            brokerURL: brokerURL,
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )
        let task = Task {
            try await client.sendAndCommit([self.makeEvent()]) {
                removedIDs.set(["event-a"])
            }
        }
        XCTAssertTrue(operation.waitUntilStarted())

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(removedIDs.get(), [])
        XCTAssertGreaterThanOrEqual(operation.closeCount, 1)
    }

    func testSuccessRacingWithCancellationDoesNotCommitQueuedIDs() async {
        let operation = CloseGatedSuccessOperation()
        let removedIDs = TestLockedBox<Set<String>>([])
        let client = TelemetryClient(
            brokerURL: brokerURL,
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )
        let task = Task {
            try await client.sendAndCommit([self.makeEvent()]) {
                removedIDs.set(["event-a"])
            }
        }
        XCTAssertTrue(operation.waitUntilCloseStarted())

        task.cancel()
        let concurrentCloseObserved = operation.waitUntilCloseCount(2)
        operation.releaseClose()
        XCTAssertTrue(concurrentCloseObserved)
        do {
            _ = try await task.value
            XCTFail("a native success racing with cancellation must not commit")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
        XCTAssertEqual(removedIDs.get(), [])
    }

    func testFlushPartitionsAtEveryIdentityBoundaryWithoutReordering() async throws {
        let original = [
            makeEvent(id: "a-1", clientID: "client-a", sessionID: "session-a"),
            makeEvent(id: "a-2", clientID: "client-a", sessionID: "session-a"),
            makeEvent(id: "b-1", clientID: "client-a", sessionID: "session-b"),
            makeEvent(id: "b-2", clientID: "client-a", sessionID: "session-b"),
            makeEvent(id: "b-3", clientID: "client-a", sessionID: "session-b"),
            makeEvent(id: "b-4", clientID: "client-a", sessionID: "session-b"),
            makeEvent(id: "c-1", clientID: "client-c", sessionID: "session-c"),
        ]
        let queue = TestLockedBox(original)
        let sent = TestLockedBox<[[TelemetryEvent]]>([])

        try await TelemetryUploadCoordinator.flush(
            maxBatchSize: 3,
            peek: { maxCount in
                Array(queue.get().prefix(maxCount))
            },
            send: { events, queuedIDs in
                sent.mutate { $0.append(events) }
                queue.mutate { queued in
                    queued = queued.filter { queuedIDs.contains($0.eventId) == false }
                }
            }
        )

        XCTAssertEqual(
            sent.get().map { $0.map(\.eventId) },
            [["a-1", "a-2"], ["b-1", "b-2", "b-3"], ["b-4"], ["c-1"]]
        )
        XCTAssertEqual(sent.get().flatMap { $0.map(\.eventId) }, original.map(\.eventId))
        XCTAssertTrue(queue.get().isEmpty)
        assertHomogeneousBatches(sent.get(), maximumCount: 3)
    }

    func testHistoricalHeadSendsHeartbeatAloneThenDrainsEveryIdentityInOrder() async throws {
        let heartbeat = makeEvent(
            id: "heartbeat",
            clientID: "client-a",
            sessionID: "session-current"
        )
        let original = [
            makeEvent(id: "old-1", clientID: "client-a", sessionID: "session-old"),
            makeEvent(id: "old-2", clientID: "client-a", sessionID: "session-old"),
            makeEvent(id: "current-1", clientID: "client-a", sessionID: "session-current"),
            makeEvent(id: "current-2", clientID: "client-a", sessionID: "session-current"),
            makeEvent(id: "current-3", clientID: "client-a", sessionID: "session-current"),
            makeEvent(id: "later-1", clientID: "client-a", sessionID: "session-later"),
        ]
        let queue = TestLockedBox(original)
        let sent = TestLockedBox<[[TelemetryEvent]]>([])

        try await TelemetryUploadCoordinator.sendHeartbeat(
            heartbeat,
            maxBatchSize: 3,
            peek: { maxCount in
                Array(queue.get().prefix(maxCount))
            },
            send: { events, queuedIDs in
                sent.mutate { $0.append(events) }
                queue.mutate { queued in
                    queued = queued.filter { queuedIDs.contains($0.eventId) == false }
                }
            }
        )

        XCTAssertEqual(
            sent.get().map { $0.map(\.eventId) },
            [
                ["heartbeat"],
                ["old-1", "old-2"],
                ["current-1", "current-2", "current-3"],
                ["later-1"],
            ]
        )
        XCTAssertEqual(
            sent.get().flatMap { $0 }.filter { $0.eventId != heartbeat.eventId }.map(\.eventId),
            original.map(\.eventId)
        )
        XCTAssertEqual(sent.get().flatMap { $0 }.filter { $0.eventId == heartbeat.eventId }.count, 1)
        XCTAssertTrue(queue.get().isEmpty)
        assertHomogeneousBatches(sent.get(), maximumCount: 3)
    }

    func testHeartbeatPiggybacksOnlyWhenQueueHeadIdentityMatches() async throws {
        let heartbeat = makeEvent(
            id: "heartbeat",
            clientID: "client-a",
            sessionID: "session-current"
        )
        let original = [
            makeEvent(id: "current-1", clientID: "client-a", sessionID: "session-current"),
            makeEvent(id: "current-2", clientID: "client-a", sessionID: "session-current"),
            makeEvent(id: "old-1", clientID: "client-a", sessionID: "session-old"),
        ]
        let queue = TestLockedBox(original)
        let sent = TestLockedBox<[[TelemetryEvent]]>([])

        try await TelemetryUploadCoordinator.sendHeartbeat(
            heartbeat,
            maxBatchSize: 3,
            peek: { maxCount in
                Array(queue.get().prefix(maxCount))
            },
            send: { events, queuedIDs in
                sent.mutate { $0.append(events) }
                queue.mutate { queued in
                    queued = queued.filter { queuedIDs.contains($0.eventId) == false }
                }
            }
        )

        XCTAssertEqual(
            sent.get().map { $0.map(\.eventId) },
            [["current-1", "current-2", "heartbeat"], ["old-1"]]
        )
        XCTAssertTrue(queue.get().isEmpty)
        assertHomogeneousBatches(sent.get(), maximumCount: 3)
    }

    func testHistoricalFlushFailureOccursAfterHeartbeatAndRetainsOldIDs() async {
        struct HistoricalFailure: Error {}
        let heartbeat = makeEvent(
            id: "heartbeat",
            clientID: "client-a",
            sessionID: "session-current"
        )
        let original = [
            makeEvent(id: "old-1", clientID: "client-a", sessionID: "session-old"),
            makeEvent(id: "old-2", clientID: "client-a", sessionID: "session-old"),
        ]
        let queue = TestLockedBox(original)
        let attempts = TestLockedBox<[[TelemetryEvent]]>([])

        do {
            try await TelemetryUploadCoordinator.sendHeartbeat(
                heartbeat,
                maxBatchSize: 3,
                peek: { maxCount in
                    Array(queue.get().prefix(maxCount))
                },
                send: { events, queuedIDs in
                    attempts.mutate { $0.append(events) }
                    if events.first?.eventId == "old-1" {
                        throw HistoricalFailure()
                    }
                    queue.mutate { queued in
                        queued = queued.filter { queuedIDs.contains($0.eventId) == false }
                    }
                }
            )
            XCTFail("expected historical flush failure")
        } catch {
            XCTAssertTrue(error is HistoricalFailure, "got \(error)")
        }

        XCTAssertEqual(
            attempts.get().map { $0.map(\.eventId) },
            [["heartbeat"], ["old-1", "old-2"]]
        )
        XCTAssertEqual(queue.get().map(\.eventId), ["old-1", "old-2"])
    }

    private func assertHomogeneousBatches(
        _ batches: [[TelemetryEvent]],
        maximumCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for batch in batches {
            XCTAssertLessThanOrEqual(batch.count, maximumCount, file: file, line: line)
            XCTAssertEqual(
                Set(batch.map { TelemetryIdentity(event: $0) }).count,
                1,
                "mixed client/session batch: \(batch.map(\.eventId))",
                file: file,
                line: line
            )
        }
    }

    private func makeEvent(
        id: String = "event-a",
        clientID: String = "client-a",
        sessionID: String = "session-a"
    ) -> TelemetryEvent {
        TelemetryEvent(
            eventId: id,
            event: "session_heartbeat",
            occurredAt: "2026-07-26T00:00:00Z",
            clientId: clientID,
            sessionId: sessionID
        )
    }
}
