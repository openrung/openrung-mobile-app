import Foundation

/// React-free request lifecycle for the classic React Native broker module.
///
/// The app target supplies the React promise shell. Hostless tests compile this file directly with
/// fake `NativeBrokerOperation` values, so request-ID ownership, cancellation, and cleanup are
/// exercised without loading React, Libbox, or a Go runtime.
final class OpenRungBrokerRequestCoordinator: @unchecked Sendable {
    typealias Completion<Value: Sendable> =
        @Sendable (Result<Value, BrokerNativeFailure>) -> Void

    private final class Entry: @unchecked Sendable {
        var task: Task<Void, Never>?
        var cancellationRequested = false
    }

    private let lock = NSLock()
    private let operationFactory: any NativeBrokerOperationFactory
    private var entries: [String: Entry] = [:]
    private var invalidated = false

    init(operationFactory: any NativeBrokerOperationFactory) {
        self.operationFactory = operationFactory
    }

    deinit {
        invalidate()
    }

    func firstReachable(
        requestID: String,
        primary: String,
        limit: Double,
        clientID: String,
        sessionID: String,
        completion: @escaping Completion<NativeBrokerRelayResultSnapshot>
    ) {
        let factory = operationFactory
        start(requestID: requestID, completion: completion) {
            guard
                limit.isFinite,
                limit.rounded(.towardZero) == limit,
                limit >= 1,
                limit <= Double(Int32.max)
            else {
                throw BrokerNativeFailure(
                    kind: .validation,
                    message: "The relay-list limit is outside the native binding range."
                )
            }

            let result: NativeBrokerRelayResultSnapshot = try await NativeBrokerRunner.run(
                factory: factory
            ) { operation in
                operation.firstReachable(
                    primary: primary,
                    limit: Int32(limit),
                    clientID: clientID,
                    sessionID: sessionID
                )
            }
            try result.throwIfFailed()

            guard
                Self.isValidAbsoluteURL(result.brokerURL),
                result.relayJSON.isEmpty == false
            else {
                throw BrokerNativeFailure(
                    kind: .decode,
                    message: "The native broker result is incomplete."
                )
            }
            return try Self.reactNativeRelayProjection(result)
        }
    }

    func runSpeedTest(
        requestID: String,
        brokerURL: String,
        completion: @escaping Completion<NativeBrokerSpeedTestResultSnapshot>
    ) {
        let factory = operationFactory
        start(requestID: requestID, completion: completion) {
            let result: NativeBrokerSpeedTestResultSnapshot = try await NativeBrokerRunner.run(
                factory: factory
            ) { operation in
                operation.runSpeedTest(brokerURL: brokerURL)
            }
            try result.throwIfFailed()

            guard
                result.bytes > 0,
                result.timeToFirstByteMilliseconds >= 0,
                result.downloadDurationMilliseconds >= 0,
                result.totalDurationMilliseconds >= 0,
                result.megabitsPerSecond.isFinite,
                result.megabitsPerSecond >= 0
            else {
                throw BrokerNativeFailure(
                    kind: .decode,
                    message: "The native speed-test result is invalid."
                )
            }
            return result
        }
    }

    func sendTelemetryBatchJSON(
        requestID: String,
        brokerURL: String,
        batchJSON: String,
        completion: @escaping Completion<NativeBrokerResultSnapshot>
    ) {
        let factory = operationFactory
        start(requestID: requestID, completion: completion) {
            let result: NativeBrokerResultSnapshot = try await NativeBrokerRunner.run(
                factory: factory
            ) { operation in
                operation.sendTelemetryBatchJSON(
                    brokerURL: brokerURL,
                    batchJSON: batchJSON
                )
            }
            try result.throwIfFailed()
            return result
        }
    }

    func fetchManifestCandidate(
        requestID: String,
        candidateURL: String,
        completion: @escaping Completion<NativeBrokerManifestResultSnapshot>
    ) {
        let factory = operationFactory
        start(requestID: requestID, completion: completion) {
            let result: NativeBrokerManifestResultSnapshot = try await NativeBrokerRunner.run(
                factory: factory
            ) { operation in
                operation.fetchManifestCandidate(candidateURL: candidateURL)
            }
            try result.throwIfFailed()

            guard Self.isValidAbsoluteURL(result.sourceURL) else {
                throw BrokerNativeFailure(
                    kind: .decode,
                    message: "The native manifest result has an invalid source URL."
                )
            }
            return result
        }
    }

    /// Cancels one active task. Repeated calls are harmless and report whether the request is
    /// still present in the registry while cancellation cleanup is in flight.
    @discardableResult
    func cancel(requestID: String) -> Bool {
        let task: Task<Void, Never>?
        lock.lock()
        guard let entry = entries[requestID] else {
            lock.unlock()
            return false
        }
        entry.cancellationRequested = true
        task = entry.task
        lock.unlock()

        task?.cancel()
        return true
    }

    /// Stops new work and cancels every active request. Completion callbacks are suppressed after
    /// invalidation because the React bridge may already be tearing down.
    func invalidate() {
        let tasks: [Task<Void, Never>]
        lock.lock()
        guard invalidated == false else {
            lock.unlock()
            return
        }
        invalidated = true
        tasks = entries.values.compactMap { entry in
            entry.cancellationRequested = true
            return entry.task
        }
        lock.unlock()

        tasks.forEach { $0.cancel() }
    }

    var activeRequestCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func start<Value: Sendable>(
        requestID: String,
        completion: @escaping Completion<Value>,
        work: @escaping @Sendable () async throws -> Value
    ) {
        guard requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            completion(.failure(BrokerNativeFailure(
                kind: .validation,
                message: "The native broker request ID is empty."
            )))
            return
        }

        let entry = Entry()
        let rejection: BrokerNativeFailure?
        lock.lock()
        if invalidated {
            rejection = Self.unavailableFailure()
        } else if entries[requestID] != nil {
            rejection = BrokerNativeFailure(
                kind: .validation,
                message: "The native broker request ID is already active."
            )
        } else {
            entries[requestID] = entry
            rejection = nil
        }
        lock.unlock()

        if let rejection {
            completion(.failure(rejection))
            return
        }

        // The task captures this coordinator weakly, avoiding a coordinator → task → coordinator
        // retain cycle. `deinit` can therefore cancel a blocked generated operation.
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Value, BrokerNativeFailure>
            do {
                result = .success(try await work())
            } catch {
                result = .failure(Self.boundedFailure(from: error))
            }
            self?.finish(
                requestID: requestID,
                entry: entry,
                result: result,
                completion: completion
            )
        }
        install(task: task, requestID: requestID, entry: entry)
    }

    private func install(
        task: Task<Void, Never>,
        requestID: String,
        entry: Entry
    ) {
        let shouldCancel: Bool
        lock.lock()
        if let current = entries[requestID], current === entry {
            current.task = task
            shouldCancel = current.cancellationRequested || invalidated
        } else {
            // A very fast task can finish and remove itself before installation. It is already
            // complete in that case, so there is no remaining operation to cancel.
            shouldCancel = false
        }
        lock.unlock()

        if shouldCancel {
            task.cancel()
        }
    }

    private func finish<Value: Sendable>(
        requestID: String,
        entry: Entry,
        result: Result<Value, BrokerNativeFailure>,
        completion: @escaping Completion<Value>
    ) {
        let shouldDeliver: Bool
        let wasCancelled: Bool
        lock.lock()
        guard let current = entries[requestID], current === entry else {
            lock.unlock()
            return
        }
        entries.removeValue(forKey: requestID)
        shouldDeliver = invalidated == false
        wasCancelled = current.cancellationRequested
        lock.unlock()

        guard shouldDeliver else { return }
        if wasCancelled {
            completion(.failure(BrokerNativeFailure(
                kind: .cancelled,
                message: "The native broker request was cancelled."
            )))
        } else {
            completion(result)
        }
    }

    private static func boundedFailure(from error: Error) -> BrokerNativeFailure {
        if error is CancellationError {
            return BrokerNativeFailure(
                kind: .cancelled,
                message: "The native broker request was cancelled."
            )
        }
        if let failure = error as? BrokerNativeFailure {
            if failure.kind == .unavailable {
                return unavailableFailure(
                    httpStatus: failure.httpStatus,
                    retryAfterMilliseconds: failure.retryAfterMilliseconds
                )
            }
            return failure
        }
        // Do not bridge arbitrary underlying diagnostics: they can contain URLs, response data, or
        // other attacker-controlled strings. Binding failures already arrive as bounded snapshots.
        return BrokerNativeFailure(
            kind: .unknown,
            message: "The native broker request failed."
        )
    }

    private static func unavailableFailure(
        httpStatus: Int? = nil,
        retryAfterMilliseconds: UInt64? = nil
    ) -> BrokerNativeFailure {
        BrokerNativeFailure(
            kind: .unavailable,
            httpStatus: httpStatus,
            retryAfterMilliseconds: retryAfterMilliseconds,
            message: "The native broker transport is unavailable; rebuild the app."
        )
    }

    /// React Native consumes only the relay directory fields. WSS fronts remain exclusively
    /// owned by PacketTunnel/native VPN code and must never cross this bridge.
    private static func reactNativeRelayProjection(
        _ result: NativeBrokerRelayResultSnapshot
    ) throws -> NativeBrokerRelayResultSnapshot {
        guard
            let data = result.relayJSON.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any],
            dictionary["relays"] is [Any]
        else {
            throw relayDecodeFailure()
        }

        let projected = removingWSSFronts(from: dictionary)
        guard
            JSONSerialization.isValidJSONObject(projected),
            let projectedData = try? JSONSerialization.data(withJSONObject: projected),
            let projectedJSON = String(data: projectedData, encoding: .utf8)
        else {
            throw relayDecodeFailure()
        }

        return NativeBrokerRelayResultSnapshot(
            succeeded: result.succeeded,
            errorKind: result.errorKind,
            errorText: result.errorText,
            httpStatus: result.httpStatus,
            retryAfterMilliseconds: result.retryAfterMilliseconds,
            brokerURL: result.brokerURL,
            relayJSON: projectedJSON,
            keyID: result.keyID,
            signatureVerified: result.signatureVerified
        )
    }

    private static func removingWSSFronts(from value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            dictionary.removeValue(forKey: "wss_fronts")
            for (key, nestedValue) in dictionary {
                dictionary[key] = removingWSSFronts(from: nestedValue)
            }
            return dictionary
        }
        if let values = value as? [Any] {
            return values.map(removingWSSFronts)
        }
        return value
    }

    private static func relayDecodeFailure() -> BrokerNativeFailure {
        BrokerNativeFailure(
            kind: .decode,
            message: "The native relay directory could not be decoded."
        )
    }

    private static func isValidAbsoluteURL(_ value: String) -> Bool {
        guard
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            let url = URL(string: value),
            url.scheme != nil,
            url.host != nil
        else {
            return false
        }
        return true
    }
}
