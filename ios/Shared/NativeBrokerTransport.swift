import Foundation

/// The closed error-kind set exported by the broker binding, plus the two bounded platform
/// failures that can occur before a usable native result exists.
public enum BrokerNativeFailureKind: String, CaseIterable, Sendable {
    case cancelled
    case timeout
    case rateLimited = "rate_limited"
    case httpStatus = "http_status"
    case dns
    case tls
    case network
    case verification
    case validation
    case unknown
    case unavailable
    case decode

    init(bindingValue: String) {
        switch bindingValue.trimmingCharacters(in: .whitespacesAndNewlines) {
        case BrokerNativeFailureKind.cancelled.rawValue:
            self = .cancelled
        case BrokerNativeFailureKind.timeout.rawValue:
            self = .timeout
        case BrokerNativeFailureKind.rateLimited.rawValue:
            self = .rateLimited
        case BrokerNativeFailureKind.httpStatus.rawValue:
            self = .httpStatus
        case BrokerNativeFailureKind.dns.rawValue:
            self = .dns
        case BrokerNativeFailureKind.tls.rawValue:
            self = .tls
        case BrokerNativeFailureKind.network.rawValue:
            self = .network
        case BrokerNativeFailureKind.verification.rawValue:
            self = .verification
        case BrokerNativeFailureKind.validation.rawValue:
            self = .validation
        case BrokerNativeFailureKind.unknown.rawValue:
            self = .unknown
        default:
            // Platform-only kinds are never accepted from the binding. Blank and future values
            // stay in the bounded unknown bucket.
            self = .unknown
        }
    }
}

/// A bounded, platform-owned projection of a failed broker binding result.
///
/// `message` is diagnostic only. Callers make policy decisions from `kind`, `httpStatus`, and
/// `retryAfterMilliseconds`; they must never parse the message.
public struct BrokerNativeFailure: LocalizedError, Equatable, Sendable {
    public let kind: BrokerNativeFailureKind
    public let httpStatus: Int?
    public let retryAfterMilliseconds: UInt64?
    public let message: String

    public init(
        kind: BrokerNativeFailureKind,
        httpStatus: Int? = nil,
        retryAfterMilliseconds: UInt64? = nil,
        message: String = ""
    ) {
        self.kind = kind
        self.httpStatus = httpStatus.flatMap { $0 > 0 ? $0 : nil }
        self.retryAfterMilliseconds = retryAfterMilliseconds.flatMap { $0 > 0 ? $0 : nil }
        self.message = Self.sanitize(message)
    }

    public init(
        bindingKind: String,
        httpStatus: Int32,
        retryAfterMilliseconds: Int64,
        message: String
    ) {
        self.init(
            kind: BrokerNativeFailureKind(bindingValue: bindingKind),
            httpStatus: httpStatus > 0 ? Int(httpStatus) : nil,
            retryAfterMilliseconds: retryAfterMilliseconds > 0
                ? UInt64(retryAfterMilliseconds)
                : nil,
            message: message
        )
    }

    public var errorDescription: String? {
        message.isEmpty ? "The native broker request failed (\(kind.rawValue))." : message
    }

    /// Local schema/configuration/linkage failures cannot improve by minting another WSS ticket.
    public var isLocalPlatformFailure: Bool {
        switch kind {
        case .validation, .unavailable, .decode:
            return true
        default:
            return false
        }
    }

    /// Existing bounded mobile dashboard taxonomy. Binding strings never become telemetry values.
    public var failureReason: String {
        switch kind {
        case .cancelled:
            return "cancelled"
        case .timeout:
            return "timeout"
        case .rateLimited:
            return "rate_limited"
        case .httpStatus:
            if httpStatus == 429 { return "rate_limited" }
            return httpStatus.map { "http_\($0)" } ?? "unknown"
        case .dns:
            return "dns_failure"
        case .tls:
            return "tls_handshake"
        case .network:
            return "network_unreachable"
        case .verification, .validation, .unknown, .unavailable, .decode:
            return "unknown"
        }
    }

    static func sanitize(_ value: String, maxBytes: Int = 256) -> String {
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let bytes = Array(collapsed.utf8)
        guard bytes.count > maxBytes else { return collapsed }
        var end = maxBytes
        while end > 0, (bytes[end] & 0xC0) == 0x80 {
            end -= 1
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

/// Common fields copied from every generated broker result before its operation is closed.
public protocol NativeBrokerResult: Sendable {
    var succeeded: Bool { get }
    var errorKind: String { get }
    var errorText: String { get }
    var httpStatus: Int32 { get }
    var retryAfterMilliseconds: Int64 { get }
}

public struct NativeBrokerResultSnapshot: NativeBrokerResult, Equatable, Sendable {
    public let succeeded: Bool
    public let errorKind: String
    public let errorText: String
    public let httpStatus: Int32
    public let retryAfterMilliseconds: Int64

    public init(
        succeeded: Bool,
        errorKind: String = "",
        errorText: String = "",
        httpStatus: Int32 = 0,
        retryAfterMilliseconds: Int64 = 0
    ) {
        self.succeeded = succeeded
        self.errorKind = errorKind
        self.errorText = BrokerNativeFailure.sanitize(errorText)
        self.httpStatus = httpStatus
        self.retryAfterMilliseconds = retryAfterMilliseconds
    }
}

public struct NativeBrokerRelayResultSnapshot: NativeBrokerResult, Equatable, Sendable {
    public let succeeded: Bool
    public let errorKind: String
    public let errorText: String
    public let httpStatus: Int32
    public let retryAfterMilliseconds: Int64
    public let brokerURL: String
    public let relayJSON: String
    public let keyID: String
    public let signatureVerified: Bool

    public init(
        succeeded: Bool,
        errorKind: String = "",
        errorText: String = "",
        httpStatus: Int32 = 0,
        retryAfterMilliseconds: Int64 = 0,
        brokerURL: String = "",
        relayJSON: String = "",
        keyID: String = "",
        signatureVerified: Bool = false
    ) {
        self.succeeded = succeeded
        self.errorKind = errorKind
        self.errorText = BrokerNativeFailure.sanitize(errorText)
        self.httpStatus = httpStatus
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.brokerURL = brokerURL
        self.relayJSON = relayJSON
        self.keyID = keyID
        self.signatureVerified = signatureVerified
    }
}

public struct NativeBrokerWSSTicketResultSnapshot:
    NativeBrokerResult,
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let succeeded: Bool
    public let errorKind: String
    public let errorText: String
    public let httpStatus: Int32
    public let retryAfterMilliseconds: Int64
    public let ticket: String
    public let url: String
    public let expiresAtMilliseconds: Int64

    public init(
        succeeded: Bool,
        errorKind: String = "",
        errorText: String = "",
        httpStatus: Int32 = 0,
        retryAfterMilliseconds: Int64 = 0,
        ticket: String = "",
        url: String = "",
        expiresAtMilliseconds: Int64 = 0
    ) {
        self.succeeded = succeeded
        self.errorKind = errorKind
        self.errorText = BrokerNativeFailure.sanitize(errorText)
        self.httpStatus = httpStatus
        self.retryAfterMilliseconds = retryAfterMilliseconds
        self.ticket = ticket
        self.url = url
        self.expiresAtMilliseconds = expiresAtMilliseconds
    }

    public var description: String {
        "NativeBrokerWSSTicketResultSnapshot(succeeded: \(succeeded), " +
            "errorKind: \(errorKind), httpStatus: \(httpStatus), " +
            "retryAfterMilliseconds: \(retryAfterMilliseconds), ticket: <redacted>, " +
            "url: <redacted>, expiresAtMilliseconds: \(expiresAtMilliseconds))"
    }

    public var debugDescription: String { description }
}

/// A single-use, synchronous native operation. Implementations copy generated results into the
/// snapshots above before returning. Hostless tests provide fakes and never load the Go runtime.
public protocol NativeBrokerOperation: AnyObject, Sendable {
    func firstReachable(
        primary: String,
        limit: Int32,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerRelayResultSnapshot?

    func sendTelemetryBatchJSON(
        brokerURL: String,
        batchJSON: String
    ) -> NativeBrokerResultSnapshot?

    func requestWSSTicket(
        brokerURL: String,
        relayID: String,
        frontID: String,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerWSSTicketResultSnapshot?

    /// May block until an in-flight Go request exits. It is idempotent and may run concurrently.
    func close()
}

public protocol NativeBrokerOperationFactory: Sendable {
    func makeOperation() -> (any NativeBrokerOperation)?
}

/// Cancellation-safe bridge for gomobile's synchronous broker selectors.
///
/// The blocking selector runs on a detached worker. Cancellation schedules `close()` on a
/// different concurrent worker because Go `Close` waits for the selector to return. The selector
/// snapshots its result first; the detached worker then closes in all cases. A post-worker
/// cancellation check prevents a success racing with cancellation from committing caller state.
public enum NativeBrokerRunner {
    public static func run<Result: Sendable>(
        factory: any NativeBrokerOperationFactory,
        invoke: @escaping @Sendable (any NativeBrokerOperation) -> Result?
    ) async throws -> Result {
        try await runImpl(
            factory: factory,
            beforeWorkerStart: {},
            invoke: invoke
        )
    }

    /// Deterministic seam for exercising cancellation after the task pre-check but before the
    /// detached worker claims permission to invoke the synchronous selector.
    static func runForTesting<Result: Sendable>(
        factory: any NativeBrokerOperationFactory,
        beforeWorkerStart: @escaping @Sendable () async -> Void,
        invoke: @escaping @Sendable (any NativeBrokerOperation) -> Result?
    ) async throws -> Result {
        try await runImpl(
            factory: factory,
            beforeWorkerStart: beforeWorkerStart,
            invoke: invoke
        )
    }

    private static func runImpl<Result: Sendable>(
        factory: any NativeBrokerOperationFactory,
        beforeWorkerStart: @escaping @Sendable () async -> Void,
        invoke: @escaping @Sendable (any NativeBrokerOperation) -> Result?
    ) async throws -> Result {
        guard let operation = factory.makeOperation() else {
            throw BrokerNativeFailure(kind: .unavailable)
        }
        let startGate = NativeBrokerStartGate()

        return try await withTaskCancellationHandler {
            // A task can already be cancelled when it reaches the runner (for example while it
            // was queued behind another actor operation). Do not let that state mint a WSS ticket
            // or start any other native request. The cancellation handler still closes the
            // freshly-created operation asynchronously.
            try Task.checkCancellation()
            await beforeWorkerStart()
            let worker = Task.detached { () -> Result? in
                // Cancellation may land after the check above but before this worker executes.
                // Only one side wins the locked claim; a cancellation winner skips Go entirely.
                guard startGate.claimStart() else { return nil }
                defer { operation.close() }
                return invoke(operation)
            }
            let result = await worker.value
            try Task.checkCancellation()
            guard let result else {
                throw BrokerNativeFailure(kind: .unavailable)
            }
            return result
        } onCancel: {
            // Mark synchronously so a not-yet-started worker cannot race ahead of asynchronous
            // Close. Close itself must remain off this stack because Go waits for in-flight work.
            startGate.cancel()
            DispatchQueue.global(qos: .utility).async {
                operation.close()
            }
        }
    }
}

private final class NativeBrokerStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var startClaimed = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard cancelled == false, startClaimed == false else { return false }
        startClaimed = true
        return true
    }
}

public extension NativeBrokerResult {
    func throwIfFailed() throws {
        guard succeeded == false else { return }
        let failure = BrokerNativeFailure(
            bindingKind: errorKind,
            httpStatus: httpStatus,
            retryAfterMilliseconds: retryAfterMilliseconds,
            message: errorText
        )
        if failure.kind == .cancelled {
            throw CancellationError()
        }
        throw failure
    }
}
