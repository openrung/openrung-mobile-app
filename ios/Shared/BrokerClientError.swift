import Foundation

/// Error surfaced by `BrokerClient`. `httpStatus` carries the raw status code so a failure can be
/// classified (429 → `rate_limited`, otherwise `http_<code>`) rather than collapsed into a generic
/// error. Kept in its own file so `FailureClassifier` and its tests can depend on it without
/// pulling in the whole networking stack.
public enum BrokerClientError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}
