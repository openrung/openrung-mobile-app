import Foundation

/// The widget's string table, resolved the way `src/i18n/index.tsx` resolves the app's: the in-app
/// selection first ('' = system), then the device's preferred language, then English. Values come
/// from `WidgetStrings.generated.swift`, rendered from `src/i18n/strings/*.ts` by
/// `npm run widget:strings`; `__tests__/core/widgetStrings.test.ts` fails when the two drift.
struct WidgetStrings: Equatable {
    /// In `SUPPORTED_TAGS` order.
    static let supportedTags: [String] = WidgetStringTables.tags
    static let rightToLeftTags: Set<String> = ["fa", "ar"]

    /// The resolved tag, always one of `supportedTags`.
    let tag: String
    private let table: [String: String]

    init(tag: String) {
        self.tag = tag
        table = WidgetStringTables.tables[tag] ?? [:]
    }

    static func current() -> WidgetStrings {
        WidgetStrings(tag: resolve(
            storedTag: WidgetSharedState.currentLanguageTag(),
            preferredLanguages: Locale.preferredLanguages
        ))
    }

    /// Port of `resolveLanguage`: exact tag, then Chinese script/region mapping, then primary subtag.
    static func resolve(storedTag: String, preferredLanguages: [String]) -> String {
        let stored = storedTag.trimmingCharacters(in: .whitespacesAndNewlines)
        let requested = stored.isEmpty ? (preferredLanguages.first ?? "en") : stored
        let lower = requested.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = supportedTags.first(where: { $0.lowercased() == lower }) {
            return exact
        }
        if lower.hasPrefix("zh") {
            let traditional = lower.contains("hant")
                || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo")
            return traditional ? "zh-TW" : "zh-CN"
        }
        let primary = lower.split(separator: "-").first.map(String.init) ?? lower
        return supportedTags.first(where: { $0.lowercased() == primary }) ?? "en"
    }

    var isRightToLeft: Bool {
        Self.rightToLeftTags.contains(tag)
    }

    var appName: String { value("appName") }
    var connect: String { value("actionConnect") }
    var widgetName: String { value("widgetName") }
    var widgetDescription: String { value("widgetDescription") }

    func label(for face: WidgetFace) -> String {
        switch face {
        case .disconnected: return value("statusDisconnected")
        case .connecting: return value("statusConnecting")
        case .connected: return value("statusConnected")
        case .disconnecting: return value("statusDisconnecting")
        case .failed: return value("statusFailed")
        }
    }

    /// Generated tables are complete per tag (English merged in at generation time); the English
    /// fallback here only guards a hand-edited table.
    private func value(_ key: String) -> String {
        table[key] ?? WidgetStringTables.tables["en"]?[key] ?? key
    }
}
