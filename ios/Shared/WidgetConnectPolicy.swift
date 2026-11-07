import Foundation

/// What the home-screen widget may ask the host app to do. The widget process never starts the
/// tunnel; `TunnelControl` applies `shouldStart` against the real `NEVPNStatus` before calling
/// the existing auto-selection connect path (nil country, nil relay).
enum WidgetDisplayPhase: String, Equatable, Sendable {
    case setupRequired
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed
}

/// OS tunnel status without importing NetworkExtension, so the policy can be tested hostlessly.
/// Unknown system values map to `connecting` at the boundary and therefore do not start.
enum WidgetSystemStatus: String, Equatable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting
}

enum WidgetClock {
    static func millis(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

enum WidgetConnectPolicy {
    /// A widget tap older than this is ignored. The app is opened immediately, so this only
    /// covers a cold launch; it must not connect the next time the app becomes active.
    static let requestTTLMillis: Int64 = 90_000
    /// Clock skew allowance. A timestamp further in the future than this is rejected.
    static let futureSkewMillis: Int64 = 60_000
    /// Collapses a widget tap that is delivered twice (extension perform plus app perform, or
    /// the short follow-up read) and keeps a widget tap from racing a manual connect or stop.
    static let duplicateStartSuppressionMillis: Int64 = 1_500

    static func phase(profileReady: Bool, status: ConnectionStatus) -> WidgetDisplayPhase {
        guard profileReady else { return .setupRequired }
        switch status {
        case .preparing, .connecting:
            return .connecting
        case .connected:
            return .connected
        case .disconnecting:
            return .disconnecting
        case .failed:
            return .failed
        case .disconnected:
            return .disconnected
        }
    }

    /// Setup has not saved a VPN profile, so the tap only opens the app. Every other phase
    /// still records a request: the snapshot can be stale, and only the app can see
    /// `NEVPNStatus`. The app drops the request when the tunnel is actually busy or up.
    static func enqueuesConnect(phase: WidgetDisplayPhase) -> Bool {
        phase != .setupRequired
    }

    static func shouldStart(
        profileReady: Bool,
        systemStatus: WidgetSystemStatus,
        commandInFlight: Bool,
        recentCommand: Bool
    ) -> Bool {
        guard profileReady, !commandInFlight, !recentCommand else { return false }
        switch systemStatus {
        case .disconnected, .invalid:
            return true
        case .connecting, .connected, .reasserting, .disconnecting:
            return false
        }
    }

    static func isFresh(issuedAtMillis: Int64, nowMillis: Int64) -> Bool {
        let age = nowMillis - issuedAtMillis
        return age >= -futureSkewMillis && age <= requestTTLMillis
    }
}
