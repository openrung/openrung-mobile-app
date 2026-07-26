import Foundation

struct TelemetryIdentity: Hashable, Sendable {
    let clientID: String
    let sessionID: String

    init(event: TelemetryEvent) {
        clientID = event.clientId
        sessionID = event.sessionId
    }
}

struct TelemetryPlannedBatch: Equatable, Sendable {
    let events: [TelemetryEvent]
    let queuedEventIDs: Set<String>
}

/// brokerapi derives identity headers from the first event and rejects a batch containing a
/// different client/session pair. Keep every native upload to one contiguous queue identity while
/// preserving FIFO order and the existing maximum batch size.
enum TelemetryBatchPlanner {
    static func homogeneousPrefix(
        _ events: [TelemetryEvent],
        maxCount: Int
    ) -> [TelemetryEvent] {
        guard maxCount > 0, let first = events.first else { return [] }
        let identity = TelemetryIdentity(event: first)
        return Array(
            events
                .prefix(maxCount)
                .prefix { TelemetryIdentity(event: $0) == identity }
        )
    }

    static func nextHeartbeatBatch(
        queued: [TelemetryEvent],
        heartbeat: TelemetryEvent,
        maxBatchSize: Int
    ) -> TelemetryPlannedBatch {
        precondition(maxBatchSize > 0)
        let heartbeatIdentity = TelemetryIdentity(event: heartbeat)

        guard let first = queued.first else {
            return TelemetryPlannedBatch(
                events: [heartbeat],
                queuedEventIDs: []
            )
        }

        if TelemetryIdentity(event: first) != heartbeatIdentity {
            // A historical head must not delay the heartbeat cadence. Send the heartbeat alone,
            // then let the coordinator drain queued identities in FIFO order.
            return TelemetryPlannedBatch(
                events: [heartbeat],
                queuedEventIDs: []
            )
        }

        // Reserve one slot for the heartbeat. A batch size of one sends the heartbeat alone, then
        // the coordinator drains the still-queued events on its next pass.
        let prefix = homogeneousPrefix(queued, maxCount: maxBatchSize - 1)
        return TelemetryPlannedBatch(
            events: prefix + [heartbeat],
            queuedEventIDs: Set(prefix.map(\.eventId))
        )
    }
}

/// Pure queue orchestration shared by TelemetryManager and hostless tests. The injected sender
/// atomically commits `queuedEventIDs` only after an uncancelled native success.
enum TelemetryUploadCoordinator {
    typealias Peek = @Sendable (_ maxCount: Int) -> [TelemetryEvent]
    typealias Send = @Sendable (
        _ events: [TelemetryEvent],
        _ queuedEventIDs: Set<String>
    ) async throws -> Void

    static func flush(
        maxBatchSize: Int,
        peek: Peek,
        send: Send
    ) async throws {
        precondition(maxBatchSize > 0)
        while true {
            try Task.checkCancellation()
            let queued = peek(maxBatchSize)
            let batch = TelemetryBatchPlanner.homogeneousPrefix(
                queued,
                maxCount: maxBatchSize
            )
            guard batch.isEmpty == false else { return }
            try await send(batch, Set(batch.map(\.eventId)))
        }
    }

    static func sendHeartbeat(
        _ heartbeat: TelemetryEvent,
        maxBatchSize: Int,
        peek: Peek,
        send: Send
    ) async throws {
        precondition(maxBatchSize > 0)
        try Task.checkCancellation()
        let plan = TelemetryBatchPlanner.nextHeartbeatBatch(
            queued: peek(maxBatchSize),
            heartbeat: heartbeat,
            maxBatchSize: maxBatchSize
        )
        try await send(plan.events, plan.queuedEventIDs)
        try await flush(maxBatchSize: maxBatchSize, peek: peek, send: send)
    }
}

/// Uploads one already-constructed telemetry batch through brokerapi's native transport.
public struct TelemetryClient: Sendable {
    private let brokerURL: URL
    private let operationFactory: any NativeBrokerOperationFactory

    public init(
        brokerURL: URL,
        operationFactory: any NativeBrokerOperationFactory
    ) {
        self.brokerURL = brokerURL
        self.operationFactory = operationFactory
    }

    public func send(_ events: [TelemetryEvent]) async throws {
        guard events.isEmpty == false else { return }

        // Encode once, then preserve those exact UTF-8 bytes when crossing the gomobile string
        // boundary. brokerapi validates the events and derives their complete identity pair.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(TelemetryBatch(events: events))
        guard let batchJSON = String(data: encoded, encoding: .utf8) else {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The telemetry batch could not be represented as UTF-8."
            )
        }

        let result: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
            factory: operationFactory
        ) { operation in
            operation.sendTelemetryBatchJSON(
                brokerURL: brokerURL.absoluteString,
                batchJSON: batchJSON
            )
        }
        try result.throwIfFailed()
    }

    /// Small commit seam used by TelemetryManager: queued IDs are removed only after an
    /// uncancelled native success. Keeping the post-send check beside the commit also makes the
    /// outbox invariant directly testable with a fake native operation.
    func sendAndCommit(
        _ events: [TelemetryEvent],
        commit: @Sendable () -> Void
    ) async throws {
        guard events.isEmpty == false else { return }
        try await send(events)
        try Task.checkCancellation()
        commit()
    }
}
