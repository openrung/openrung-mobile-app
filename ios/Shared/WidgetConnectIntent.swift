import AppIntents

/// The widget button's intent (iOS 17+). `openAppWhenRun` (and `supportedModes` on iOS 26+) makes
/// the system launch OpenRung and run `perform()` inside the app process — a widget extension cannot
/// load a tunnel manager — where it drops a request into the mailbox the RN bridge collects. It has
/// no parameters by design: nothing on the home screen can choose a relay, country or broker.
@available(iOS 17.0, *)
struct WidgetConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect OpenRung"
    static let description = IntentDescription("Connects OpenRung to an automatically chosen relay.")
    static let openAppWhenRun = true
    /// Widget-only: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }

    func perform() async throws -> some IntentResult {
        WidgetConnectMailbox.shared.submit(WidgetConnectRequest(source: .intent, issuedAt: Date()))
        return .result()
    }
}

/// The same button once the app has a saved VPN profile (`WidgetBackgroundConnect`). Conforming to
/// `LiveActivityIntent` is what makes the system run `perform()` in the app's process without
/// opening the app, launching it in the background when it is not running; that is all the
/// conformance is used for. Like `WidgetConnectIntent` it has no parameters.
@available(iOS 17.0, *)
struct WidgetBackgroundConnectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Connect OpenRung in the background"
    static let description = IntentDescription(
        "Connects OpenRung to an automatically chosen relay without opening the app."
    )
    /// Widget-only: keep it out of Shortcuts and Spotlight.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await WidgetBackgroundConnect.shared.run()
        return .result()
    }
}
