import Foundation

/// Runs the same-relay direct ladder used by Android: a punched QUIC bridge first when one can be
/// established, followed by the relay hub's ordinary Reality endpoint. A successfully established
/// bridge that cannot carry end-to-end traffic is a remote path failure and may fall through; local
/// engine/platform failures and cancellation remain terminal.
struct PunchFallbackPolicy {
    func connect<T>(
        attemptPunch: () async throws -> T?,
        attemptRelayHub: () async throws -> T,
        onPunchFallback: (DirectPathError) async -> Void
    ) async throws -> T {
        do {
            if let punched = try await attemptPunch() {
                return punched
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as DirectPathError {
            if containsTunnelCancellation(error) { throw CancellationError() }
            await onPunchFallback(error)
        } catch {
            throw error
        }
        return try await attemptRelayHub()
    }
}
