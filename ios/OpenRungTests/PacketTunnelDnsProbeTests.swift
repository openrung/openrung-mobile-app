import Foundation
import XCTest

final class PacketTunnelDnsProbeTests: XCTestCase {
    func testAcceptsAMatchingResponseIncludingNXDOMAIN() async throws {
        let transport = ScriptedDatagramTransport(respondWith: .echoTransactionID(rcode: 3))
        let probe = PacketTunnelDnsProbe(transport: transport)
        try await probe.verifyOnce()
        let exchanged = await transport.queries()
        XCTAssertEqual(exchanged.count, 1)
    }

    func testEachAttemptUsesAFreshNonceSoNoCacheCanAnswer() async throws {
        let transport = ScriptedDatagramTransport(respondWith: .echoTransactionID(rcode: 0))
        let probe = PacketTunnelDnsProbe(transport: transport)
        try await probe.verifyOnce()
        try await probe.verifyOnce()
        let qnames = await transport.queries().map(Self.decodeQname)
        XCTAssertEqual(qnames.count, 2)
        XCTAssertNotEqual(qnames[0], qnames[1])
        for qname in qnames {
            XCTAssertTrue(qname.hasSuffix(".\(ProbeTargets.dnsProbeQnameSuffix)"))
        }
    }

    func testMismatchedResponseFailsTheAttemptRatherThanPassingSilently() async {
        let transport = ScriptedDatagramTransport(respondWith: .zeroedHeader)
        let probe = PacketTunnelDnsProbe(transport: transport)
        do {
            try await probe.verifyOnce()
            XCTFail("a mismatched response must not verify the DNS path")
        } catch {
            XCTAssertTrue(isGenuineRemoteDataPathFailure(error))
        }
    }

    func testTransportTimeoutSurfacesAsGenuineRemoteFailure() async {
        let transport = ScriptedDatagramTransport(respondWith: .neverAnswer)
        let probe = PacketTunnelDnsProbe(transport: transport, attemptTimeoutMilliseconds: 50)
        do {
            try await probe.verifyOnce()
            XCTFail("a silent transport must time the attempt out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
            XCTAssertTrue(isGenuineRemoteDataPathFailure(error))
        }
    }

    func testVerifyRetriesUntilTheDeadlineAndKeepsTheLastError() async {
        let transport = ScriptedDatagramTransport(respondWith: .throwError(URLError(.cannotConnectToHost)))
        // Wide margins: the transport throws instantly while the timeout child sleeps 500 ms, so
        // a loaded-CI scheduler stall cannot flip the observed error or the retry count.
        let probe = PacketTunnelDnsProbe(
            transport: transport,
            deadlineMilliseconds: 500,
            retryDelayNanoseconds: 1_000_000,
            attemptTimeoutMilliseconds: 500
        )
        do {
            try await probe.verify()
            XCTFail("verify must fail once the deadline passes")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        let attempts = await transport.queries().count
        XCTAssertGreaterThanOrEqual(attempts, 2, "verify must retry within its deadline")
    }

    private static func decodeQname(_ query: Data) -> String {
        let bytes = [UInt8](query)
        var labels: [String] = []
        var offset = 12
        while offset < bytes.count, bytes[offset] != 0 {
            let length = Int(bytes[offset])
            let start = offset + 1
            labels.append(String(bytes: bytes[start..<(start + length)], encoding: .ascii) ?? "")
            offset += 1 + length
        }
        return labels.joined(separator: ".")
    }
}

/// Scripted through-tunnel datagram fake, mirroring FakeThroughTunnelTransport's shape.
private actor ScriptedDatagramTransport: ThroughTunnelDatagramTransport {
    enum Behavior {
        case echoTransactionID(rcode: UInt8)
        case zeroedHeader
        case neverAnswer
        case throwError(Error)
    }

    private let behavior: Behavior
    private var exchanged: [Data] = []

    init(respondWith behavior: Behavior) {
        self.behavior = behavior
    }

    func queries() -> [Data] { exchanged }

    func exchange(_ datagram: Data) async throws -> Data {
        exchanged.append(datagram)
        switch behavior {
        case .echoTransactionID(let rcode):
            let bytes = [UInt8](datagram.prefix(2))
            return Data([bytes[0], bytes[1], 0x81, 0x80 | rcode, 0, 0, 0, 0, 0, 0, 0, 0])
        case .zeroedHeader:
            return Data(count: 12)
        case .neverAnswer:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
        case .throwError(let error):
            throw error
        }
    }
}
