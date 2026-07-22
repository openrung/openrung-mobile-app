import Foundation
import Network

// RelayReachabilityError moved to RelayReachabilityError.swift so FailureClassifier and its tests
// can depend on it without this Network-backed implementation.

/// One-shot continuation ownership for a reachability attempt. Cancellation can run before the
/// checked continuation is installed, so the first result is retained and replayed to a later
/// installer. This also makes cancelling the underlying `NWConnection` independent of whether
/// Network happens to deliver its `.cancelled` state callback.
final class RelayReachabilityCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Int64, Error>?
    private var continuation: CheckedContinuation<Int64, Error>?

    /// Returns `true` when the caller still owns starting the connection. A result that arrived
    /// first is resumed here and returns `false` so a pre-cancelled task never opens a socket.
    @discardableResult
    func install(_ continuation: CheckedContinuation<Int64, Error>) -> Bool {
        let pendingResult: Result<Int64, Error>?
        lock.lock()
        if let result {
            pendingResult = result
        } else {
            self.continuation = continuation
            pendingResult = nil
        }
        lock.unlock()

        if let pendingResult {
            continuation.resume(with: pendingResult)
            return false
        }
        return true
    }

    /// Claims the attempt's terminal outcome. Only the winner may clean up the connection.
    @discardableResult
    func resolve(_ result: Result<Int64, Error>) -> Bool {
        let installedContinuation: CheckedContinuation<Int64, Error>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return false
        }
        self.result = result
        installedContinuation = continuation
        continuation = nil
        lock.unlock()

        installedContinuation?.resume(with: result)
        return true
    }
}

/// Measures TCP connect latency to a relay endpoint. Port of Android `RelayReachability.checkTcp`.
public enum RelayReachability {
    public static func checkTcp(_ relay: RelayDescriptor, timeoutMillis: Int = 5_000) async throws -> Int64 {
        try await checkTcp(host: relay.publicHost, port: relay.publicPort, timeoutMillis: timeoutMillis)
    }

    public static func checkTcp(host rawHost: String, port: Int, timeoutMillis: Int = 5_000) async throws -> Int64 {
        let host = rawHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        guard port > 0, port <= 65_535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw RelayReachabilityError.invalidPort
        }

        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "com.openrung.app.reachability")
        let startedNs = DispatchTime.now().uptimeNanoseconds
        let completion = RelayReachabilityCompletion()

        @Sendable func finish(_ result: Result<Int64, Error>) {
            guard completion.resolve(result) else { return }
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int64, Error>) in
                connection.stateUpdateHandler = { state in
                    guard let result = terminalResult(for: state, startedNs: startedNs) else { return }
                    finish(result)
                }

                guard completion.install(continuation) else {
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    return
                }
                queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMillis)) {
                    finish(.failure(RelayReachabilityError.timeout))
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            // Do not rely solely on NWConnection delivering `.cancelled`: the continuation must
            // complete even when cancellation happens before start or the callback is suppressed.
            finish(.failure(CancellationError()))
        }
    }

    /// Pure state mapping kept internal so the `.cancelled` regression can assert the exact
    /// Network.framework outcome without opening a socket.
    static func terminalResult(
        for state: NWConnection.State,
        startedNs: UInt64,
        nowNs: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Result<Int64, Error>? {
        switch state {
        case .ready:
            return .success(Int64((nowNs - startedNs) / 1_000_000))
        case .failed(let error), .waiting(let error):
            return .failure(error)
        case .cancelled:
            // A cancelled connection is a cancellation outcome, never a reachability timeout. In
            // particular, user stop must not become a relay-health penalty.
            return .failure(CancellationError())
        default:
            return nil
        }
    }
}
