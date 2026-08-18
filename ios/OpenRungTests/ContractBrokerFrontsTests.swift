import Foundation
import XCTest

/// The Swift half of the shared broker-front snapshot.
///
/// This app owns no racing — it hands native brokerapi a primary and Go races the built-in
/// candidates — so the phases and candidate ordering in the vectors belong to the Go suite and are
/// deliberately not asserted here. What this side can claim, and what catches a front rotated in
/// openrung and not here, is that every front the app hardcodes is still one of the canonical ones.
/// A front that quietly stops existing is a fallback a blocked user no longer has.
final class ContractBrokerFrontsTests: XCTestCase {

    private static let expectedVersion = 1
    private static let suite = "swift"

    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenRungTests
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("testdata/contract/broker_fronts.json")
        vectors = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
            "broker_fronts.json is not a JSON object"
        )
    }

    private func canonicalFronts() throws -> [String] {
        try XCTUnwrap(vectors["default_order"] as? [String])
    }

    func testRunsTheVersionAndSuiteItWasWrittenFor() throws {
        XCTAssertEqual(vectors["version"] as? Int, Self.expectedVersion)
        let declared = try XCTUnwrap(vectors["suites"] as? [String])
        XCTAssertTrue(declared.contains(Self.suite))
    }

    func testEveryHardcodedFrontIsCanonical() throws {
        let fronts = try canonicalFronts()
        XCTAssertFalse(AppConfig.defaultBrokerURLs.isEmpty)
        for url in AppConfig.defaultBrokerURLs {
            XCTAssertTrue(fronts.contains(url.absoluteString), "\(url) is not in the canonical front list")
        }
    }

    func testPrimaryAndTelemetryTargetsAreCanonical() throws {
        let fronts = try canonicalFronts()
        XCTAssertTrue(fronts.contains(AppConfig.defaultBrokerURL.absoluteString))
        // A telemetry target off the canonical list would carry the pre-VPN IP and the stable
        // client id to a host the directory contract never vouched for.
        XCTAssertTrue(fronts.contains(AppConfig.telemetryBrokerURL.absoluteString))
    }

    func testAppCarriesASubsetOfTheCanonicalFronts() throws {
        // Recorded rather than asserted as equality: this app deliberately ships fewer fronts than
        // brokerapi races. If it ever grew to the full list, this is where that shows up.
        XCTAssertLessThanOrEqual(AppConfig.defaultBrokerURLs.count, try canonicalFronts().count)
    }
}
