import NetworkExtension

extension WidgetConnectPolicy.SystemTunnel {
    /// `.invalid` (no configuration) and `.disconnected` are the only OS states a widget connect may
    /// start from; everything else is a tunnel in motion that the widget must leave alone.
    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid, .disconnected:
            self = .down
        case .connecting, .connected, .reasserting, .disconnecting:
            self = .live
        @unknown default:
            self = .live
        }
    }
}
