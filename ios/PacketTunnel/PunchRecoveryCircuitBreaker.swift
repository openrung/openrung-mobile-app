import Foundation

/// Recovery action after a previously connected direct punch path is lost.
///
/// Every case retains the same measurements so the caller can log recovery without consulting
/// mutable breaker state. `countedFailure` is false only when the loss was caused by a physical
/// network outage.
enum PunchRecoveryDecision: Equatable, Sendable {
    case retryDirect(
        delayMilliseconds: UInt64,
        rapidFailureCount: Int,
        directUptimeMilliseconds: UInt64,
        countedFailure: Bool
    )
    case useRelayHub(
        delayMilliseconds: UInt64,
        rapidFailureCount: Int,
        directUptimeMilliseconds: UInt64,
        countedFailure: Bool
    )

    var delayMilliseconds: UInt64 {
        switch self {
        case let .retryDirect(delay, _, _, _), let .useRelayHub(delay, _, _, _):
            return delay
        }
    }

    var rapidFailureCount: Int {
        switch self {
        case let .retryDirect(_, count, _, _), let .useRelayHub(_, count, _, _):
            return count
        }
    }

    var directUptimeMilliseconds: UInt64 {
        switch self {
        case let .retryDirect(_, _, uptime, _), let .useRelayHub(_, _, uptime, _):
            return uptime
        }
    }

    var countedFailure: Bool {
        switch self {
        case let .retryDirect(_, _, _, counted), let .useRelayHub(_, _, _, counted):
            return counted
        }
    }

    /// Keeps recovery backoff owned by the caller's task, so disconnecting or manually
    /// reconnecting cancels the pending retry.
    func awaitBackoff() async throws {
        guard delayMilliseconds > 0 else { return }
        let nanoseconds = delayMilliseconds.multipliedReportingOverflow(by: 1_000_000)
        try await Task.sleep(
            nanoseconds: nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue
        )
    }
}

/// Bounds recovery churn from a direct path that repeatedly reaches connected and then dies.
///
/// State is isolated by relay. The owning packet-tunnel task must serialize access, matching the
/// Android service's single-dispatcher ownership; this type performs no internal synchronization.
final class PunchRecoveryCircuitBreaker {
    static let stablePathMilliseconds: UInt64 = 5 * 60_000
    static let maximumRapidFailures = 3
    static let initialBackoffMilliseconds: UInt64 = 2_000
    static let maximumBackoffMilliseconds: UInt64 = 30_000

    typealias JitterSelector = (_ allowedDelay: ClosedRange<UInt64>) -> UInt64

    private struct RelayState {
        var rapidFailureCount = 0
        var directConnectedAtMilliseconds: UInt64?
        var circuitOpen = false
    }

    private let stablePathMilliseconds: UInt64
    private let maximumRapidFailures: Int
    private let initialBackoffMilliseconds: UInt64
    private let maximumBackoffMilliseconds: UInt64
    private let chooseJitteredDelay: JitterSelector
    private var relayStates: [String: RelayState] = [:]

    init(
        stablePathMilliseconds: UInt64 = PunchRecoveryCircuitBreaker.stablePathMilliseconds,
        maximumRapidFailures: Int = PunchRecoveryCircuitBreaker.maximumRapidFailures,
        initialBackoffMilliseconds: UInt64 =
            PunchRecoveryCircuitBreaker.initialBackoffMilliseconds,
        maximumBackoffMilliseconds: UInt64 =
            PunchRecoveryCircuitBreaker.maximumBackoffMilliseconds,
        chooseJitteredDelay: @escaping JitterSelector = { UInt64.random(in: $0) }
    ) {
        precondition(stablePathMilliseconds > 0, "stablePathMilliseconds must be positive")
        precondition(maximumRapidFailures > 0, "maximumRapidFailures must be positive")
        precondition(initialBackoffMilliseconds > 0, "initialBackoffMilliseconds must be positive")
        precondition(
            maximumBackoffMilliseconds >= initialBackoffMilliseconds,
            "maximumBackoffMilliseconds must be at least initialBackoffMilliseconds"
        )
        self.stablePathMilliseconds = stablePathMilliseconds
        self.maximumRapidFailures = maximumRapidFailures
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.maximumBackoffMilliseconds = maximumBackoffMilliseconds
        self.chooseJitteredDelay = chooseJitteredDelay
    }

    func markDirectConnected(relayID: String, nowElapsedMilliseconds: UInt64) {
        requireRelayID(relayID)
        var state = relayStates[relayID] ?? RelayState()
        state.directConnectedAtMilliseconds = nowElapsedMilliseconds
        relayStates[relayID] = state
    }

    func allowsDirectPunch(relayID: String) -> Bool {
        relayStates[relayID]?.circuitOpen != true
    }

    /// Records a lost direct path and returns the recovery action.
    ///
    /// Passing `countTowardBreaker` as false for a physical-network outage preserves any earlier
    /// rapid-failure streak, adds no delay, and never opens the circuit. A path that survived the
    /// stable-path threshold clears its earlier streak before the current loss is considered.
    func onDirectPathLost(
        relayID: String,
        nowElapsedMilliseconds: UInt64,
        countTowardBreaker: Bool
    ) -> PunchRecoveryDecision {
        requireRelayID(relayID)
        var state = relayStates[relayID] ?? RelayState()
        let connectedAt = state.directConnectedAtMilliseconds
        state.directConnectedAtMilliseconds = nil
        let directUptime: UInt64
        if let connectedAt, nowElapsedMilliseconds >= connectedAt {
            directUptime = nowElapsedMilliseconds - connectedAt
        } else {
            directUptime = 0
        }

        if directUptime >= stablePathMilliseconds {
            state.rapidFailureCount = 0
            state.circuitOpen = false
        }

        guard countTowardBreaker else {
            relayStates[relayID] = state
            return .retryDirect(
                delayMilliseconds: 0,
                rapidFailureCount: state.rapidFailureCount,
                directUptimeMilliseconds: directUptime,
                countedFailure: false
            )
        }

        state.rapidFailureCount += 1
        let delay = recoveryDelayMilliseconds(failureCount: state.rapidFailureCount)
        if state.rapidFailureCount >= maximumRapidFailures {
            state.circuitOpen = true
            relayStates[relayID] = state
            return .useRelayHub(
                delayMilliseconds: delay,
                rapidFailureCount: state.rapidFailureCount,
                directUptimeMilliseconds: directUptime,
                countedFailure: true
            )
        }

        relayStates[relayID] = state
        return .retryDirect(
            delayMilliseconds: delay,
            rapidFailureCount: state.rapidFailureCount,
            directUptimeMilliseconds: directUptime,
            countedFailure: true
        )
    }

    /// Explicit user connect or disconnect starts a new recovery epoch.
    func reset() {
        relayStates.removeAll()
    }

    private func recoveryDelayMilliseconds(failureCount: Int) -> UInt64 {
        var nominal = initialBackoffMilliseconds
        if failureCount > 1 {
            for _ in 1..<failureCount {
                if nominal >= maximumBackoffMilliseconds / 2 {
                    nominal = maximumBackoffMilliseconds
                } else {
                    nominal = min(nominal * 2, maximumBackoffMilliseconds)
                }
            }
        }

        let jitter = nominal / 5
        let minimum = max(nominal - jitter, 1)
        let addition = nominal.addingReportingOverflow(jitter)
        let maximum = min(
            addition.overflow ? UInt64.max : addition.partialValue,
            maximumBackoffMilliseconds
        )
        let allowedDelay = minimum...maximum
        return min(max(chooseJitteredDelay(allowedDelay), minimum), maximum)
    }

    private func requireRelayID(_ relayID: String) {
        precondition(
            relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            "relayID must not be blank"
        )
    }
}
