import Foundation
import XCTest

final class DnsResolverRotationTests: XCTestCase {
    func testStartsWithTheDefaultResolverOrder() {
        XCTAssertEqual(DnsResolverRotation().currentServers(), ["1.1.1.1", "8.8.8.8"])
    }

    func testAFailureOfTheCurrentOrderAdvancesExactlyOnce() {
        let rotation = DnsResolverRotation()
        let failed = rotation.currentServers()

        XCTAssertTrue(rotation.noteDnsPathFailure(failed))
        XCTAssertEqual(rotation.currentServers(), ["8.8.8.8", "1.1.1.1"])

        // A duplicate report of the already-rotated-away order must not advance again —
        // otherwise a startup race plus the health loop could skip an untried resolver.
        XCTAssertFalse(rotation.noteDnsPathFailure(failed))
        XCTAssertEqual(rotation.currentServers(), ["8.8.8.8", "1.1.1.1"])
    }

    func testRotationWrapsAroundTheResolverList() {
        let rotation = DnsResolverRotation()
        XCTAssertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))
        XCTAssertTrue(rotation.noteDnsPathFailure(rotation.currentServers()))
        XCTAssertEqual(rotation.currentServers(), ["1.1.1.1", "8.8.8.8"])
    }

    func testCustomResolverListsRotateTheSameWay() {
        let rotation = DnsResolverRotation(resolvers: ["a", "b", "c"])
        XCTAssertTrue(rotation.noteDnsPathFailure(["a", "b", "c"]))
        XCTAssertEqual(rotation.currentServers(), ["b", "c", "a"])
        XCTAssertTrue(rotation.noteDnsPathFailure(["b", "c", "a"]))
        XCTAssertEqual(rotation.currentServers(), ["c", "a", "b"])
    }
}
