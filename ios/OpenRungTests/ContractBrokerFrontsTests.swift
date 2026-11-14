import Foundation
import XCTest

/// The Swift half of the shared broker-front snapshot.
///
/// This app owns no racing — it hands native brokerapi a primary and Go races the built-in
/// candidates — so the phases and candidate ordering in the vectors belong to the Go suite and are
/// deliberately not asserted here. What this side can claim, and what catches a front rotated in
/// openrung and not here, is that the primary the app configures is still one of the canonical ones.
final class ContractBrokerFrontsTests: XCTestCase {

    private static let expectedVersion = 3
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

    func testConfiguredPrimaryIsCanonical() throws {
        let fronts = try canonicalFronts()
        XCTAssertTrue(
            fronts.contains(AppConfig.defaultBrokerURL.absoluteString),
            "\(AppConfig.defaultBrokerURL) is not in the canonical front list"
        )
    }
}
