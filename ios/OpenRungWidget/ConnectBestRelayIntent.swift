import AppIntents
import Foundation

/// Home-screen button. `openAppWhenRun` foregrounds the host app; there is no public API that
/// starts a third-party packet tunnel from a widget process, and this intent does not invent one.
/// The widget build only stores the app-group request. The app build consumes it and calls
/// `TunnelControl`, which is not linked into the extension.
@available(iOS 17.0, *)
struct ConnectBestRelayIntent: AppIntent {
    static var title: LocalizedStringResource = "Connect OpenRung"
    static var description = IntentDescription("Connect OpenRung to the automatic relay.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        if let store = WidgetAppGroup.store {
            WidgetConnectHandoff.recordWidgetTap(store: store, nowMillis: WidgetClock.millis())
        }
        #if !OPENRUNG_WIDGET_EXTENSION
        await WidgetAutoConnectBridge.handleAppIntent()
        #endif
        return .result()
    }
}
