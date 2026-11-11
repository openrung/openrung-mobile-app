import Foundation

/// Whether a collected request may start a tunnel. Evaluated in the app at collection time against
/// the shared snapshot (as reconciled with the OS) and the OS's own view of the tunnel.
enum WidgetConnectPolicy {
    /// `NEVPNStatus` folded to what matters here; the app maps it (`WidgetSystemTunnel.swift`) so
    /// this file, which the widget also compiles, never imports NetworkExtension.
    enum SystemTunnel: Equatable {
        /// No configuration loaded, `.invalid`, or `.disconnected`.
        case down
        /// `.connecting`, `.connected`, `.reasserting` or `.disconnecting`.
        case live
    }

    enum Decision: Equatable {
        case start
        case ignore(Reason)

        enum Reason: String {
            /// The shared snapshot says preparing/connecting/connected/disconnecting.
            case sharedStateBusy
            /// The OS still reports a live tunnel, whatever the snapshot says.
            case systemTunnelLive
        }
    }

    /// A widget tap never switches, restarts or stops anything that is running (including a tunnel
    /// the user pointed at a chosen country); it only starts from a fully down state.
    static func decide(sharedStatus: ConnectionStatus, systemTunnel: SystemTunnel) -> Decision {
        if sharedStatus.isWorking || sharedStatus.isConnected {
            return .ignore(.sharedStateBusy)
        }
        if systemTunnel == .live {
            return .ignore(.systemTunnelLive)
        }
        return .start
    }
}
