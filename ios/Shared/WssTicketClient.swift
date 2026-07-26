import Foundation

struct WssSessionTicket: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Opaque bearer credential. It must never enter a URL, log, metric or error message.
    let ticket: String
    let expiresAt: Date
    /// Broker-echoed URL, compared byte-for-byte with the selected signed front by the caller.
    let url: String

    func isFresh(at now: Date) -> Bool {
        expiresAt > now
    }

    var description: String {
        "WssSessionTicket(ticket: <redacted>, expiresAt: \(expiresAt), url: <redacted>)"
    }

    var debugDescription: String { description }
}

struct WssTicketStatusError: Error, Equatable {
    let status: Int
    let retryAfterMilliseconds: UInt64?
}

struct WssTicketPolicy: Equatable, Sendable {
    let totalDeadlineMilliseconds: UInt64
    let perAttemptMilliseconds: UInt64
    let defaultRetryAfterMilliseconds: UInt64
    let maxRetryAfterMilliseconds: UInt64

    init(
        totalDeadlineMilliseconds: UInt64 = 15_000,
        perAttemptMilliseconds: UInt64 = 5_000,
        defaultRetryAfterMilliseconds: UInt64 = 10_000,
        maxRetryAfterMilliseconds: UInt64 = 30_000
    ) {
        precondition(totalDeadlineMilliseconds > 0)
        precondition(perAttemptMilliseconds > 0)
        precondition(defaultRetryAfterMilliseconds > 0)
        precondition(maxRetryAfterMilliseconds > 0)
        self.totalDeadlineMilliseconds = totalDeadlineMilliseconds
        self.perAttemptMilliseconds = perAttemptMilliseconds
        self.defaultRetryAfterMilliseconds = defaultRetryAfterMilliseconds
        self.maxRetryAfterMilliseconds = maxRetryAfterMilliseconds
    }
}

typealias WssTicketAttempt = @Sendable (
    _ brokerURL: URL,
    _ relayID: String,
    _ frontID: String,
    _ clientID: String?,
    _ sessionID: String?,
    _ timeoutMilliseconds: UInt64
) async throws -> WssSessionTicket

/// Policy-preserving WSS ticket client. Front ordering, total/per-attempt budgets, first-error
/// semantics, and the bounded 429/503 retry round remain Swift-owned; each individual transport
/// attempt is one fresh brokerapi operation.
final class WssTicketClient: @unchecked Sendable {
    private let operationFactory: any NativeBrokerOperationFactory

    init(operationFactory: any NativeBrokerOperationFactory) {
        self.operationFactory = operationFactory
    }

    func requestWithFailover(
        brokerURLs: [URL],
        relayID: String,
        frontID: String,
        clientID: String? = nil,
        sessionID: String? = nil
    ) async throws -> WssSessionTicket {
        try await Self.requestWithFailover(
            brokerURLs: brokerURLs,
            relayID: relayID,
            frontID: frontID,
            clientID: clientID,
            sessionID: sessionID,
            policy: WssTicketPolicy(),
            monotonicMilliseconds: {
                UInt64(max(ProcessInfo.processInfo.systemUptime * 1_000, 0))
            },
            wait: { milliseconds in
                let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
                try await Task.sleep(
                    nanoseconds: nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
                )
            },
            attempt: { [operationFactory] brokerURL, requestedRelayID, requestedFrontID,
                requestedClientID, requestedSessionID, timeout in
                try await Self.requestOnce(
                    operationFactory: operationFactory,
                    brokerURL: brokerURL,
                    relayID: requestedRelayID,
                    frontID: requestedFrontID,
                    clientID: requestedClientID,
                    sessionID: requestedSessionID,
                    timeoutMilliseconds: timeout
                )
            }
        )
    }

    /// Injectable orchestration core. Fronts are sequential under one deadline; only 429/503 may
    /// schedule one additional round, after a bounded Retry-After wait.
    static func requestWithFailover(
        brokerURLs: [URL],
        relayID: String,
        frontID: String,
        clientID: String?,
        sessionID: String?,
        policy: WssTicketPolicy,
        monotonicMilliseconds: @Sendable () -> UInt64,
        wait: @Sendable (UInt64) async throws -> Void,
        attempt: @escaping WssTicketAttempt
    ) async throws -> WssSessionTicket {
        guard relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BrokerNativeFailure(kind: .validation, message: "The relay ID is empty.")
        }
        guard frontID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BrokerNativeFailure(kind: .validation, message: "The WSS front ID is empty.")
        }
        var fronts: [URL] = []
        for url in brokerURLs where fronts.contains(url) == false {
            fronts.append(url)
        }
        guard fronts.isEmpty == false else {
            throw BrokerNativeFailure(kind: .validation, message: "No WSS ticket broker is available.")
        }

        let started = monotonicMilliseconds()
        let deadline = saturatedAdd(started, policy.totalDeadlineMilliseconds)
        var firstFailure: Error?
        var scheduledRetryDelay: UInt64?

        for round in 0...1 {
            for brokerURL in fronts {
                try Task.checkCancellation()
                let remaining = remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds())
                guard remaining > 0 else { throw firstFailure ?? URLError(.timedOut) }
                let attemptTimeout = min(policy.perAttemptMilliseconds, remaining)
                do {
                    return try await withTimeout(milliseconds: attemptTimeout) {
                        try await attempt(
                            brokerURL,
                            relayID,
                            frontID,
                            clientID,
                            sessionID,
                            attemptTimeout
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let failure as BrokerNativeFailure where failure.isLocalPlatformFailure {
                    // Another front cannot repair a stale binding, nil result, or local schema
                    // mismatch. Abort before another short-lived bearer credential is minted.
                    throw failure
                } catch {
                    if firstFailure == nil { firstFailure = error }
                    if round == 0, let candidate = retryDelay(for: error, policy: policy) {
                        scheduledRetryDelay = max(scheduledRetryDelay ?? 0, candidate)
                    }
                }
            }

            if round == 1 { break }
            guard let delay = scheduledRetryDelay else {
                throw firstFailure ?? URLError(.cannotConnectToHost)
            }
            guard let firstFailure else { throw URLError(.cannotConnectToHost) }
            let remaining = remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds())
            guard delay < remaining else { throw firstFailure }
            try await wait(delay)
            try Task.checkCancellation()
            guard remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds()) > 0 else {
                throw firstFailure
            }
        }
        throw firstFailure ?? URLError(.cannotConnectToHost)
    }

    static func requestOnce(
        operationFactory: any NativeBrokerOperationFactory,
        brokerURL: URL,
        relayID: String,
        frontID: String,
        clientID: String? = nil,
        sessionID: String? = nil,
        timeoutMilliseconds _: UInt64 = 5_000
    ) async throws -> WssSessionTicket {
        let result: NativeBrokerWSSTicketResultSnapshot = try await NativeBrokerRunner.run(
            factory: operationFactory
        ) { operation in
            operation.requestWSSTicket(
                brokerURL: brokerURL.absoluteString,
                relayID: relayID,
                frontID: frontID,
                clientID: clientID ?? "",
                sessionID: sessionID ?? ""
            )
        }

        do {
            try result.throwIfFailed()
        } catch let failure as BrokerNativeFailure {
            if failure.isLocalPlatformFailure {
                throw failure
            }
            if let status = failure.httpStatus {
                throw WssTicketStatusError(
                    status: status,
                    retryAfterMilliseconds: failure.retryAfterMilliseconds
                )
            }
            throw failure
        }

        // Foundation's Date accepts non-finite/out-of-domain values. Keep the conversion bounded
        // to positive Unix milliseconds through the end of year 9999.
        let maximumUnixMilliseconds: Int64 = 253_402_300_799_999
        guard (1...maximumUnixMilliseconds).contains(result.expiresAtMilliseconds) else {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The native WSS ticket expiry is invalid."
            )
        }
        let seconds = Double(result.expiresAtMilliseconds) / 1_000
        guard seconds.isFinite else {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The native WSS ticket expiry is invalid."
            )
        }
        let expiresAt = Date(timeIntervalSince1970: seconds)
        guard expiresAt.timeIntervalSince1970.isFinite else {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The native WSS ticket expiry is invalid."
            )
        }
        return WssSessionTicket(ticket: result.ticket, expiresAt: expiresAt, url: result.url)
    }

    private static func retryDelay(for error: Error, policy: WssTicketPolicy) -> UInt64? {
        guard let status = error as? WssTicketStatusError, status.status == 429 || status.status == 503 else {
            return nil
        }
        let requested = status.retryAfterMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            ?? policy.defaultRetryAfterMilliseconds
        return min(requested, policy.maxRetryAfterMilliseconds)
    }

    private static func withTimeout<T: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
                try await Task.sleep(
                    nanoseconds: nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
                )
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    private static func saturatedAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        value.addingReportingOverflow(increment).overflow ? UInt64.max : value + increment
    }

    private static func remainingMilliseconds(deadline: UInt64, now: UInt64) -> UInt64 {
        now >= deadline ? 0 : deadline - now
    }
}
