import Foundation

/// What one widget timeline entry shows. Built only from the app-group snapshot and the
/// profile-ready flag. It does not claim the OS tunnel is up: a crashed extension can leave a
/// stale connected snapshot until the host app reconciles `NEVPNStatus` and writes it back.
struct WidgetViewModel: Equatable, Sendable {
    var phase: WidgetDisplayPhase
    var statusLine: String
    var detailLine: String?
    var buttonTitle: String
    var accessibilityLabel: String
    var rightToLeft: Bool
    /// False until a VPN profile has been saved. The button still opens the app.
    var enqueuesConnect: Bool

    static func load(
        profileReady: Bool,
        languageTag: String,
        systemLocale: String,
        snapshot: ConnectionStateSnapshot
    ) -> WidgetViewModel {
        let resolved = WidgetStrings.resolve(tag: languageTag, systemLocale: systemLocale)
        let phase = WidgetConnectPolicy.phase(profileReady: profileReady, status: snapshot.status)
        let statusLine = statusText(phase, resolved: resolved)
        let detailLine = detailText(phase, snapshot: snapshot, resolved: resolved)
        let buttonTitle = buttonText(phase, resolved: resolved)
        let action = phase == .setupRequired || buttonTitle == WidgetStrings.text("openContentDescription", resolvedTag: resolved)
            ? WidgetStrings.text("widgetAccessibilityOpen", resolvedTag: resolved)
            : WidgetStrings.text("widgetAccessibilityConnect", resolvedTag: resolved)
        var spoken = [action, statusLine]
        if let detailLine, detailLine.isEmpty == false {
            spoken.append(detailLine)
        }
        return WidgetViewModel(
            phase: phase,
            statusLine: statusLine,
            detailLine: detailLine,
            buttonTitle: buttonTitle,
            accessibilityLabel: spoken.joined(separator: ". "),
            rightToLeft: WidgetStrings.isRightToLeft(resolved),
            enqueuesConnect: WidgetConnectPolicy.enqueuesConnect(phase: phase)
        )
    }

    /// Gallery and redacted placeholder. Does not report a live connection.
    static let placeholder = WidgetViewModel(
        phase: .disconnected,
        statusLine: WidgetStrings.text("statusDisconnected", resolvedTag: "en"),
        detailLine: WidgetStrings.text("relayAuto", resolvedTag: "en"),
        buttonTitle: WidgetStrings.text("actionConnect", resolvedTag: "en"),
        accessibilityLabel: WidgetStrings.text("widgetAccessibilityConnect", resolvedTag: "en"),
        rightToLeft: false,
        enqueuesConnect: false
    )

    private static func statusText(_ phase: WidgetDisplayPhase, resolved: String) -> String {
        switch phase {
        case .setupRequired:
            return WidgetStrings.text("widgetSetupTitle", resolvedTag: resolved)
        case .disconnected:
            return WidgetStrings.text("statusDisconnected", resolvedTag: resolved)
        case .connecting:
            return WidgetStrings.text("statusConnecting", resolvedTag: resolved)
        case .connected:
            return WidgetStrings.text("statusConnected", resolvedTag: resolved)
        case .disconnecting:
            return WidgetStrings.text("statusDisconnecting", resolvedTag: resolved)
        case .failed:
            return WidgetStrings.text("statusFailed", resolvedTag: resolved)
        }
    }

    private static func buttonText(_ phase: WidgetDisplayPhase, resolved: String) -> String {
        switch phase {
        case .disconnected, .failed:
            return WidgetStrings.text("actionConnect", resolvedTag: resolved)
        case .setupRequired, .connecting, .connected, .disconnecting:
            return WidgetStrings.text("openContentDescription", resolvedTag: resolved)
        }
    }

    private static func detailText(
        _ phase: WidgetDisplayPhase,
        snapshot: ConnectionStateSnapshot,
        resolved: String
    ) -> String? {
        switch phase {
        case .setupRequired:
            return WidgetStrings.text("widgetSetupDetail", resolvedTag: resolved)
        case .disconnected, .connecting:
            return WidgetStrings.text("relayAuto", resolvedTag: resolved)
        case .connected:
            let label = snapshot.relayLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let label, label.isEmpty == false { return truncate(label) }
            let name = snapshot.relayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, name.isEmpty == false { return truncate(name) }
            return WidgetStrings.text("relayAuto", resolvedTag: resolved)
        case .disconnecting:
            return nil
        case .failed:
            switch snapshot.lastErrorCode {
            case "access_denied":
                return WidgetStrings.text("errorAccessDenied", resolvedTag: resolved)
            case "enrollment_refused":
                return WidgetStrings.text("errorEnrollmentRefused", resolvedTag: resolved)
            default:
                guard let error = snapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines),
                      error.isEmpty == false
                else { return nil }
                return truncate(error)
            }
        }
    }

    static func truncate(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
