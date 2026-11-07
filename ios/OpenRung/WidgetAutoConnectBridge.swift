import Foundation

/// Foreground handoff from the home-screen widget. A pending app-group request is the only
/// authorization to start; a URL or an AppIntent that did not record one opens the app and stops.
/// Two deliveries of the same tap (the in-app intent plus `sceneDidBecomeActive`, or the short
/// follow-up) collapse in `TunnelControl.startAutoBestRelayIfIdle`.
enum WidgetAutoConnectBridge {
    /// Observes widget taps while this process is running, including when it is already
    /// foregrounded and `sceneDidBecomeActive` does not run again.
    static func install() {
        let observer = Unmanaged.passUnretained(WidgetConnectDarwinObserver.shared).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, _, _, _, _ in
                Task { @MainActor in
                    await WidgetAutoConnectBridge.fulfillPendingRequest()
                }
            },
            AppConfig.widgetConnectDarwinNotificationName as CFString,
            nil,
            .deliverImmediately
        )
    }

    static func noteForeground() {
        Task { @MainActor in
            await fulfillPendingRequest()
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await fulfillPendingRequest()
        }
    }

    static func handleAppIntent() async {
        await fulfillPendingRequest()
    }

    static func handle(url: URL) {
        guard WidgetConnectURL.classify(url) != nil else { return }
        noteForeground()
    }

    @MainActor
    private static func fulfillPendingRequest() async {
        guard let store = WidgetAppGroup.store else { return }
        guard WidgetConnectRequestStore.consume(from: store, nowMillis: WidgetClock.millis()) != nil else {
            return
        }
        await TunnelControl.shared.startAutoBestRelayIfIdle()
    }
}

/// Retained Darwin observer. The center does not retain the pointer it is given.
private final class WidgetConnectDarwinObserver {
    static let shared = WidgetConnectDarwinObserver()
}
