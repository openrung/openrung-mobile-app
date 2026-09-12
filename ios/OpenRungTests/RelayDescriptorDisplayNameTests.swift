import XCTest

/// Swift counterpart of RelayDescriptorDisplayNameTest.kt and relayDisplayName.test.ts.
final class RelayDescriptorDisplayNameTests: XCTestCase {
    func testTrimsLabelsAndCollapsesWhitespace() {
        XCTAssertEqual(makeWssTestRelay(label: "  proud-falcon  ").displayName(), "proud-falcon")
        for label in ["proud \t\n  falcon", "proud\u{A0}\u{A0}falcon",
                      "proud\u{3000}falcon", "proud\u{2028}\u{2029}falcon"] {
            XCTAssertEqual(makeWssTestRelay(label: label).displayName(), "proud falcon")
        }
    }

    func testStripsControlBidiAndAstralFormatCharacters() {
        XCTAssertEqual(makeWssTestRelay(label: "\u{202E}npj.yaler").displayName(), "npj.yaler")
        for label in ["proud\u{7}fal\u{1B}con", "proud\u{200B}\u{200D}falcon", "proud\u{E0061}falcon"] {
            XCTAssertEqual(makeWssTestRelay(label: label).displayName(), "proudfalcon")
        }
    }

    func testClampsAt24CodePointsWithoutSplittingAstralCharacters() {
        XCTAssertEqual(makeWssTestRelay(label: String(repeating: "x", count: 80)).displayName(),
            String(repeating: "x", count: 24))
        XCTAssertEqual(makeWssTestRelay(label: String(repeating: "🚀", count: 30)).displayName(),
            String(repeating: "🚀", count: 24))
        XCTAssertEqual(makeWssTestRelay(label: String(repeating: "x", count: 23) + "🚀rocket").displayName(),
            String(repeating: "x", count: 23) + "🚀")
    }

    func testAbsentBlankOrUnprintableLabelsUseCompactID() {
        for label: String? in [nil, "", "   ", "\u{202E}\u{200B}\u{7}"] {
            XCTAssertEqual(makeWssTestRelay(id: "relay_03a7324205e22463b4919345337c96fa", label: label).displayName(),
                "03a7324205e2")
        }
        XCTAssertEqual(makeWssTestRelay(id: "relay-1").displayName(), "relay-1")
    }

    func testFallbackIDIsSanitizedAndClampedByCodePoint() {
        XCTAssertEqual(makeWssTestRelay(id: "relay_\u{202E}0123456789abcdef").displayName(), "0123456789ab")
        XCTAssertEqual(makeWssTestRelay(id: "relay_" + String(repeating: "🚀", count: 20)).displayName(),
            String(repeating: "🚀", count: 12))
    }
}
