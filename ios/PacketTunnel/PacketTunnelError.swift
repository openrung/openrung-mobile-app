import Foundation

/// Connection-flow errors raised by `PacketTunnelProvider`.
///
/// `relayUnreachable` and `allRelaysFailed` carry the underlying `Error` (not just a message) so
/// `FailureClassifier` can unwrap and classify the real root cause — a per-relay TCP failure or the
/// last relay attempt's error — instead of reporting the generic wrapper. Kept in its own file so
/// the classifier and its tests can depend on it without the NetworkExtension-backed provider.
enum PacketTunnelError: LocalizedError {
    case noUsableRelay
    case noRelayInCountry(String)
    case relayNotAvailable
    case relayUnreachable(host: String, port: Int, underlying: Error?)
    case allRelaysFailed(Error?)

    var errorDescription: String? {
        switch self {
        case .noUsableRelay:
            return "No usable VLESS Reality Vision direct-exit relay is available."
        case .noRelayInCountry(let countryName):
            return "No volunteer relay available in \(countryName) right now."
        case .relayNotAvailable:
            return "The selected relay is no longer available."
        case .relayUnreachable(let host, let port, _):
            return "Relay \(host):\(port) is not reachable from this device."
        case .allRelaysFailed(let underlying):
            if let underlying {
                return "All relay connection attempts failed. Last error: \(FailureClassifier.describe(underlying))"
            }
            return "All relay connection attempts failed."
        }
    }
}
