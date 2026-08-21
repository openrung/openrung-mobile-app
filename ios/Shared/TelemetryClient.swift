import Foundation
#if canImport(Libbox)
import Libbox
#endif

/// Boundary to the bound native telemetry outbox — the shared Go implementation that owns the
/// on-disk NDJSON queue in the App Group container, its cap and compaction, the pre-0.3.5
/// array-format migration, the identity-homogeneous upload batching, the heartbeat piggyback
/// rule, and brokerapi posting (`android/punchbridge/telemetry_binding.go`). It replaces the
/// independent Swift outbox (`TelemetryOutbox` + `TelemetryOutboxState`) and this file's former
/// planner/coordinator/client stack; the queue policy is pinned by the Go suite against the real
/// binding. This file keeps its name because the Xcode targets list files explicitly (xcodegen);
/// renaming it means regenerating the project.
public protocol TelemetryOutboxHandling: Sendable {
    /// Persists one event (a `TelemetryEvent` as JSON); false when the event was undecodable.
    func enqueue(_ eventJson: String) -> Bool

    /// Back-patches attributes onto the queued events of one session (the geo patch).
    func applySessionAttributes(sessionId: String, attributesJson: String)

    func pendingCount() -> Int

    /// Prepares one single-use, cancelable upload attempt. The manager creates one per request
    /// and closes it from its cancellation handler; the begin/close gate lives inside the bound
    /// upload's own mutex, so a close that lands before the request begins wins and the native
    /// call never starts — tunnel shutdown is never held hostage by an unresponsive broker,
    /// whichever side of the start the cancellation lands on.
    func beginUpload() -> any TelemetryUploadHandling
}

/// One single-use, cancelable native upload (see `TelemetryOutboxHandling.beginUpload`).
public protocol TelemetryUploadHandling: Sendable {
    /// Uploads at most one batch from the queue head, removing it on success. Blocking network
    /// I/O — call off the cooperative pool. The caller loops with a fresh upload per batch until
    /// `NativeTelemetryFlushOutcome.pendingCount` reaches zero, keeping cancellation between
    /// requests.
    func flushNextBatch(brokerURL: String) -> NativeTelemetryFlushOutcome

    /// Uploads one heartbeat, letting the queue head piggyback only when it carries the
    /// heartbeat's own client/session identity. Blocking network I/O.
    func sendHeartbeat(brokerURL: String, heartbeatJson: String) -> NativeTelemetryFlushOutcome

    /// Idempotent: cancels a blocked request (which returns promptly with the cancelled outcome
    /// and commits nothing), prevents a not-yet-started one from ever starting, and waits until
    /// any in-flight attempt has returned. The outbox itself stays open.
    func close()
}

/// One native flush outcome, carrying the broker binding's bounded error taxonomy.
public struct NativeTelemetryFlushOutcome: Equatable, Sendable {
    public let succeeded: Bool
    public let errorKind: String
    public let errorText: String
    public let httpStatus: Int32
    public let retryAfterMilliseconds: Int64
    public let sentCount: Int
    public let pendingCount: Int

    public init(
        succeeded: Bool,
        errorKind: String = "",
        errorText: String = "",
        httpStatus: Int32 = 0,
        retryAfterMilliseconds: Int64 = 0,
        sentCount: Int = 0,
        pendingCount: Int = 0
    ) {
        self.succeeded = succeeded
        self.errorKind = errorKind
        self.errorText = errorText
        self.httpStatus = httpStatus
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.sentCount = sentCount
        self.pendingCount = pendingCount
    }

    /// Converts an unsuccessful outcome into the same bounded `BrokerNativeFailure` contract
    /// every other native broker call throws, so telemetry upload failures keep their existing
    /// shape at the call sites.
    public func failure(operationName: String) -> BrokerNativeFailure {
        BrokerNativeFailure(
            bindingKind: errorKind,
            httpStatus: httpStatus,
            retryAfterMilliseconds: retryAfterMilliseconds,
            message: errorText.isEmpty ? "\(operationName) failed" : "\(operationName) failed: \(errorText)"
        )
    }
}

#if canImport(Libbox)

/// Production handle over the gomobile outbox object, opened in the App Group container so the
/// extension's queue survives process death exactly as before.
public final class NativeTelemetryOutbox: TelemetryOutboxHandling, @unchecked Sendable {
    private let outbox: LibboxOpenRungTelemetryOutboxProtocol?

    public init() {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)?
            .path
        outbox = directory.flatMap { path in
            LibboxNewOpenRungTelemetryOutboxForIOS(
                path,
                AppConfig.telemetryOutboxFilename,
                DeviceAttributes.appVersion,
                DeviceAttributes.osVersion
            )
        }
    }

    public func enqueue(_ eventJson: String) -> Bool {
        outbox?.enqueue(eventJson) ?? false
    }

    public func applySessionAttributes(sessionId: String, attributesJson: String) {
        _ = outbox?.applySessionAttributes(sessionId, attributesJSON: attributesJson)
    }

    public func pendingCount() -> Int {
        Int(outbox?.pendingCount() ?? 0)
    }

    public func beginUpload() -> any TelemetryUploadHandling {
        NativeTelemetryUpload(upload: outbox?.beginUpload())
    }
}

private final class NativeTelemetryUpload: TelemetryUploadHandling, @unchecked Sendable {
    private let upload: LibboxOpenRungTelemetryUpload?

    init(upload: LibboxOpenRungTelemetryUpload?) {
        self.upload = upload
    }

    func flushNextBatch(brokerURL: String) -> NativeTelemetryFlushOutcome {
        outcome(upload?.flushNextBatch(brokerURL))
    }

    func sendHeartbeat(brokerURL: String, heartbeatJson: String) -> NativeTelemetryFlushOutcome {
        outcome(upload?.sendHeartbeat(brokerURL, heartbeatJSON: heartbeatJson))
    }

    func close() {
        upload?.close()
    }

    private func outcome(_ result: LibboxOpenRungTelemetryFlushResult?) -> NativeTelemetryFlushOutcome {
        guard let result else {
            return NativeTelemetryFlushOutcome(succeeded: false, errorKind: "unavailable")
        }
        return NativeTelemetryFlushOutcome(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis(),
            sentCount: Int(result.sentCount()),
            pendingCount: Int(result.pendingCount())
        )
    }
}

#endif
