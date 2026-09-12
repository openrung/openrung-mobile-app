import Foundation

/// Error surfaced by the embedded libbox/sing-box proxy engine. Kept in its own file so
/// `FailureClassifier` and its tests can depend on it without linking Libbox. Classifies as
/// `process_exited` — the embedded-engine analogue of the Go clients' sing-box subprocess dying.
enum PacketTunnelProxyEngineError: LocalizedError {
    case engineNotLinked
    case engineStartFailed(String)

    var errorDescription: String? {
        switch self {
        case .engineNotLinked:
            return "Libbox.xcframework is not linked yet. Build sing-box lib_apple and add Libbox to the PacketTunnel target."
        case .engineStartFailed(let message):
            return "The embedded VLESS Reality Vision engine failed to start: \(message)"
        }
    }
}
