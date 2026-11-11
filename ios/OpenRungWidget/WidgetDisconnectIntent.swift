import AppIntents
import Foundation

/// The widget's Disconnect button (iOS 17+). Unlike `WidgetConnectIntent` it is compiled into the
/// widget extension only and does not ask for the app, so the system runs `perform()` here, in the
/// background: the tap never opens OpenRung. The extension cannot stop a tunnel itself; it leaves a
/// request for the tunnel to end itself (`WidgetDisconnectRequest`). It has no parameters: there is
/// one tunnel, and stopping it needs nothing chosen.
@available(iOS 17.0, *)
struct WidgetDisconnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect OpenRung"
    static let description = IntentDescription("Disconnects OpenRung.")
    /// Widget-only: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetDisconnectRequest.submit()
        // WidgetKit rebuilds the timeline when this returns. Give the tunnel a moment to settle so
        // that rebuild lands on the final face; if it takes longer, the rebuild shows the pending
        // request as "disconnecting" and refreshes itself.
        let deadline = Date().addingTimeInterval(WidgetDisconnectRequest.settleWait)
        while WidgetSharedState.tunnelIsLive(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        return .result()
    }
}
