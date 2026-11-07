import Foundation
import XCTest

/// Language resolution for the widget mirrors `resolveLanguage` in src/i18n/index.tsx, and the
/// generated table is complete for every supported tag.
final class WidgetStringsTests: XCTestCase {
    private let allTags = ["en", "zh-CN", "zh-TW", "fa", "ru", "ar", "tr", "vi", "my"]

    func testGeneratedTablesCoverEveryTagAndKey() {
        XCTAssertEqual(WidgetStringTables.tags, allTags)
        for tag in allTags {
            let table = WidgetStringTables.tables[tag]
            XCTAssertNotNil(table, tag)
            for key in WidgetStringTables.keys {
                XCTAssertFalse(table?[key]?.isEmpty ?? true, "\(tag).\(key)")
            }
        }
    }

    func testEveryAccessorResolvesWithoutFallingBackToTheKeyName() {
        for tag in allTags {
            let strings = WidgetStrings(tag: tag)
            let values = [
                strings.appName, strings.connect, strings.relayAuto,
                strings.widgetName, strings.widgetDescription,
                strings.label(for: .disconnected), strings.label(for: .connecting),
                strings.label(for: .connected), strings.label(for: .disconnecting),
                strings.label(for: .failed),
            ]
            for value in values {
                XCTAssertFalse(value.isEmpty, tag)
                XCTAssertFalse(WidgetStringTables.keys.contains(value), "\(tag) fell back to key \(value)")
            }
        }
    }

    func testStatusLabelsMatchTheAppsEnglish() {
        let strings = WidgetStrings(tag: "en")
        XCTAssertEqual(strings.label(for: .disconnected), ConnectionStatus.disconnected.displayLabel)
        XCTAssertEqual(strings.label(for: .connecting), ConnectionStatus.connecting.displayLabel)
        XCTAssertEqual(strings.label(for: .connected), ConnectionStatus.connected.displayLabel)
        XCTAssertEqual(strings.label(for: .disconnecting), ConnectionStatus.disconnecting.displayLabel)
        XCTAssertEqual(strings.label(for: .failed), ConnectionStatus.failed.displayLabel)
        XCTAssertEqual(strings.connect, "CONNECT")
    }

    func testStoredTagWinsOverTheDevicePreference() {
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "fa", preferredLanguages: ["en-US"]), "fa")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: " ru ", preferredLanguages: ["en-US"]), "ru")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "ZH-tw", preferredLanguages: ["en-US"]), "zh-TW")
    }

    func testSystemDefaultFollowsTheDevicePreference() {
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["tr-TR", "en-US"]), "tr")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["vi"]), "vi")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["my-MM"]), "my")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: []), "en")
    }

    func testChineseScriptAndRegionMapping() {
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh-Hans-CN"]), "zh-CN")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh-Hant-TW"]), "zh-TW")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh-HK"]), "zh-TW")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh-MO"]), "zh-TW")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh-SG"]), "zh-CN")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["zh"]), "zh-CN")
    }

    func testUnsupportedLanguagesFallBackToEnglish() {
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "", preferredLanguages: ["de-DE", "fr-FR"]), "en")
        XCTAssertEqual(WidgetStrings.resolve(storedTag: "xx", preferredLanguages: ["fa-IR"]), "en")
    }

    func testRightToLeftOnlyForPersianAndArabic() {
        XCTAssertTrue(WidgetStrings(tag: "fa").isRightToLeft)
        XCTAssertTrue(WidgetStrings(tag: "ar").isRightToLeft)
        for tag in allTags where tag != "fa" && tag != "ar" {
            XCTAssertFalse(WidgetStrings(tag: tag).isRightToLeft, tag)
        }
    }
}
