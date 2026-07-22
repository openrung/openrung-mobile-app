import Foundation
import XCTest

final class PacketTunnelInternetProbeTests: XCTestCase {
    func testInjectedThroughTunnelTransportIsTheOnlyProbePath() async throws {
        let transport = FakeThroughTunnelTransport(responses: [
            .failure(URLError(.timedOut)),
            .success(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)),
        ])
        let probe = try PacketTunnelInternetProbe(
            endpoints: [
                "https://first.example/generate_204",
                "https://second.example/check?probe=1",
            ],
            transport: transport,
            deadlineMilliseconds: 500,
            retryDelayNanoseconds: 1_000_000,
            requestTimeoutMilliseconds: 100
        )

        let result = try await probe.verifyOnce()

        XCTAssertEqual(result.endpoint, "https://second.example/check?probe=1")
        XCTAssertEqual(
            transport.requestedEndpoints,
            [
                try TunnelProbeEndpoint("https://first.example/generate_204"),
                try TunnelProbeEndpoint("https://second.example/check?probe=1"),
            ]
        )
    }

    func testEndpointRequiresHttpsAndBuildsAHostBoundRequest() throws {
        let endpoint = try TunnelProbeEndpoint("https://probe.example:8443/a%20b?q=1")
        XCTAssertEqual(endpoint.host, "probe.example")
        XCTAssertEqual(endpoint.port, 8443)
        XCTAssertEqual(endpoint.requestTarget, "/a%20b?q=1")
        let request = String(decoding: endpoint.httpRequest, as: UTF8.self)
        XCTAssertTrue(request.hasPrefix("GET /a%20b?q=1 HTTP/1.1\r\n"))
        XCTAssertTrue(request.contains("Host: probe.example:8443\r\n"))
        XCTAssertTrue(
            String(decoding: try TunnelProbeEndpoint("https://probe.example/").httpRequest, as: UTF8.self)
                .contains("Host: probe.example\r\n")
        )
        XCTAssertThrowsError(try TunnelProbeEndpoint("http://probe.example/"))
        XCTAssertThrowsError(try TunnelProbeEndpoint("https://user@probe.example/"))
    }

    func testHttpStatusParserAcceptsOnlyAValidBoundedResponseHead() throws {
        XCTAssertEqual(
            try PacketTunnelInternetProbe.parseHTTPStatus(Data("HTTP/1.1 204 No Content\r\n\r\n".utf8)),
            204
        )
        XCTAssertEqual(
            try PacketTunnelInternetProbe.parseHTTPStatus(Data("HTTP/2 200\r\n\r\n".utf8)),
            200
        )
        XCTAssertThrowsError(
            try PacketTunnelInternetProbe.parseHTTPStatus(Data("not-http\r\n\r\n".utf8))
        )
        XCTAssertThrowsError(
            try PacketTunnelInternetProbe.parseHTTPStatus(Data(repeating: 65, count: 16 * 1_024 + 1))
        )
    }

    func testFailedThroughTunnelSweepSurfacesRemotePathEvidence() async throws {
        let transport = FakeThroughTunnelTransport(responses: [
            .failure(URLError(.networkConnectionLost)),
            .failure(URLError(.timedOut)),
        ])
        let probe = try PacketTunnelInternetProbe(
            endpoints: ["https://one.example/", "https://two.example/"],
            transport: transport,
            requestTimeoutMilliseconds: 100
        )
        do {
            _ = try await probe.verifyOnce()
            XCTFail("expected failed through-tunnel sweep")
        } catch {
            XCTAssertTrue(isGenuineRemoteDataPathFailure(error))
        }
    }
}

private final class FakeThroughTunnelTransport: ThroughTunnelHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [Result<Data, Error>]
    private var storedEndpoints: [TunnelProbeEndpoint] = []

    init(responses: [Result<Data, Error>]) {
        self.responses = responses
    }

    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data {
        let response = lock.withLock {
            storedEndpoints.append(endpoint)
            return responses.removeFirst()
        }
        return try response.get()
    }

    var requestedEndpoints: [TunnelProbeEndpoint] {
        lock.withLock { storedEndpoints }
    }
}
