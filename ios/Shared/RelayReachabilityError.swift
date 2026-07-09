import Foundation

/// Error surfaced by `RelayReachability.checkTcp`. Kept in its own file so `FailureClassifier` and
/// its tests can depend on it without pulling in the `Network`-backed reachability implementation.
public enum RelayReachabilityError: Error, Equatable {
    case invalidPort
    case timeout
}
