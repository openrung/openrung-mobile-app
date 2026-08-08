import Foundation
import XCTest

final class DnsProbeMessageTests: XCTestCase {
    func testQueryEncodesWellFormedRecursionDesiredAQuestion() {
        let query = DnsProbeMessage.query(transactionID: 0xBEEF, name: "abc.probe.openrung.org")
        let bytes = [UInt8](query)

        XCTAssertEqual(bytes[0], 0xBE)
        XCTAssertEqual(bytes[1], 0xEF)
        XCTAssertEqual(bytes[2], 0x01) // RD
        XCTAssertEqual(bytes[3], 0x00)
        XCTAssertEqual(Int(bytes[4]) << 8 | Int(bytes[5]), 1) // QDCOUNT

        var offset = 12
        for label in ["abc", "probe", "openrung", "org"] {
            XCTAssertEqual(Int(bytes[offset]), label.count)
            let start = offset + 1
            XCTAssertEqual(String(bytes: bytes[start..<(start + label.count)], encoding: .ascii), label)
            offset += 1 + label.count
        }
        XCTAssertEqual(bytes[offset], 0) // root label
        XCTAssertEqual(Int(bytes[offset + 2]), 1) // QTYPE A
        XCTAssertEqual(Int(bytes[offset + 4]), 1) // QCLASS IN
        XCTAssertEqual(bytes.count, offset + 5)
    }

    func testAnyResponseWithMatchingIdCountsIncludingNXDOMAIN() {
        // NXDOMAIN is expected until the wildcard probe record exists; the response arriving at
        // all is what proves the hijack -> DoH -> proxy path.
        let nxdomain = Data([0xBE, 0xEF, 0x81, 0x83, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertTrue(DnsProbeMessage.isResponse(nxdomain, transactionID: 0xBEEF))
    }

    func testMismatchedIdTruncatedHeaderOrEchoedQueryAreRejected() {
        let response = Data([0xBE, 0xEF, 0x80, 0x00, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertFalse(DnsProbeMessage.isResponse(response, transactionID: 0xBEEE))
        XCTAssertFalse(DnsProbeMessage.isResponse(response.prefix(11), transactionID: 0xBEEF))
        // QR clear = our own query bounced back; that proves nothing.
        let echo = DnsProbeMessage.query(transactionID: 0xBEEF, name: "abc.probe.openrung.org")
        XCTAssertFalse(DnsProbeMessage.isResponse(echo, transactionID: 0xBEEF))
    }

    func testNonceLabelsAreFreshAndDNSSafe() {
        let first = DnsProbeMessage.nonceLabel()
        let second = DnsProbeMessage.nonceLabel()
        XCTAssertEqual(first.count, 16)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.isLowercase || $0.isNumber })
    }
}
