import Foundation
import XCTest

final class PacketTunnelInternetProbeTests: XCTestCase {
    func testDefaultsUseOnlyTheDedicatedForcedProxyHostname() throws {
        XCTAssertEqual(
            PacketTunnelInternetProbe.defaultEndpointStrings,
            ["https://cp.cloudflare.com/generate_204"]
        )
        let endpoint = try TunnelProbeEndpoint(
            XCTUnwrap(PacketTunnelInternetProbe.defaultEndpointStrings.first)
        )
        XCTAssertEqual(endpoint.host, SingBoxConfiguration.connectivityProbeHost)
        XCTAssertNotEqual(endpoint.host, "www.gstatic.com")
    }

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
        XCTAssertEqual(transport.resolvedHosts, ["first.example", "second.example"])
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

    func testDNSProbeBuildsAQueryAndRequiresMatchingSuccessfulAResponse() throws {
        let transactionID: UInt16 = 0x1234
        let query = try TunnelDNSAProbe.makeQuery(
            host: SingBoxConfiguration.connectivityProbeHost,
            transactionID: transactionID
        )
        XCTAssertEqual(Array(query.prefix(6)), [0x12, 0x34, 0x01, 0x00, 0x00, 0x01])
        XCTAssertNotNil(query.range(of: Data("cloudflare".utf8)))

        let response = makeDNSResponse(
            from: query,
            transactionID: transactionID,
            address: [104, 16, 132, 229]
        )
        XCTAssertNoThrow(
            try TunnelDNSAProbe.validateResponse(response, transactionID: transactionID)
        )
        XCTAssertThrowsError(
            try TunnelDNSAProbe.validateResponse(response, transactionID: 0xabcd)
        )
    }

    func testDNSProbeRejectsMalformedFailureAndEmptyReplies() throws {
        let transactionID: UInt16 = 0x4567
        let query = try TunnelDNSAProbe.makeQuery(host: "cp.cloudflare.com", transactionID: transactionID)

        XCTAssertThrowsError(
            try TunnelDNSAProbe.validateResponse(Data([0x45, 0x67]), transactionID: transactionID)
        )
        XCTAssertThrowsError(
            try TunnelDNSAProbe.validateResponse(
                makeDNSResponse(
                    from: query,
                    transactionID: transactionID,
                    responseCode: 2,
                    address: nil
                ),
                transactionID: transactionID
            )
        )
        XCTAssertThrowsError(
            try TunnelDNSAProbe.validateResponse(
                makeDNSResponse(from: query, transactionID: transactionID, address: nil),
                transactionID: transactionID
            )
        )
        var invalidCompression = makeDNSResponse(
            from: query,
            transactionID: transactionID,
            address: [104, 16, 132, 229]
        )
        invalidCompression[query.count] = 0xff
        invalidCompression[query.count + 1] = 0xff
        XCTAssertThrowsError(
            try TunnelDNSAProbe.validateResponse(
                invalidCompression,
                transactionID: transactionID
            )
        )
    }

    func testFreshDNSFailurePreventsTheHTTPSProbe() async throws {
        let transport = FakeThroughTunnelTransport(
            dnsResponses: [.failure(URLError(.dnsLookupFailed))],
            responses: [
                .success(Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)),
            ]
        )
        let probe = try PacketTunnelInternetProbe(
            endpoints: ["https://cp.cloudflare.com/generate_204"],
            transport: transport,
            requestTimeoutMilliseconds: 100
        )

        do {
            _ = try await probe.verifyOnce()
            XCTFail("DNS failure must keep the HTTPS gate closed")
        } catch {
            XCTAssertTrue(isGenuineRemoteDataPathFailure(error))
        }

        XCTAssertEqual(transport.resolvedHosts, ["cp.cloudflare.com"])
        XCTAssertTrue(transport.requestedEndpoints.isEmpty)
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

    func testChinaBypassWithDirectInternetButDeadProxyNeverPassesStartupGate() async throws {
        let configuration = chinaBypassConfiguration()
        let transport = RoutingAwareProbeTransport(
            configuration: configuration,
            directInternetAvailable: true,
            proxyAvailable: false
        )
        let probe = try PacketTunnelInternetProbe(
            transport: transport,
            deadlineMilliseconds: 5,
            retryDelayNanoseconds: 1_000_000,
            requestTimeoutMilliseconds: 100
        )
        var connectedPublicationCount = 0

        do {
            _ = try await StartupConnectionPublicationGate.run(
                establishAndVerify: { try await probe.verify() },
                publishConnected: { _ in connectedPublicationCount += 1 }
            )
        } catch {
            XCTAssertTrue(isGenuineRemoteDataPathFailure(error))
        }

        XCTAssertEqual(connectedPublicationCount, 0)
        XCTAssertFalse(transport.selectedPaths.isEmpty)
        XCTAssertTrue(transport.selectedPaths.allSatisfy { $0 == .proxy })
    }

    func testChinaBypassWithWorkingProxyPassesStartupGate() async throws {
        let transport = RoutingAwareProbeTransport(
            configuration: chinaBypassConfiguration(),
            directInternetAvailable: true,
            proxyAvailable: true
        )
        let probe = try PacketTunnelInternetProbe(
            transport: transport,
            requestTimeoutMilliseconds: 100
        )
        var connectedPublicationCount = 0

        _ = try await StartupConnectionPublicationGate.run(
            establishAndVerify: { try await probe.verifyOnce() },
            publishConnected: { _ in connectedPublicationCount += 1 }
        )

        XCTAssertEqual(connectedPublicationCount, 1)
        XCTAssertEqual(transport.selectedPaths, [.proxy, .proxy])
    }

    private func makeDNSResponse(
        from query: Data,
        transactionID: UInt16,
        responseCode: UInt8 = 0,
        address: [UInt8]?
    ) -> Data {
        var response = query
        response[0] = UInt8(transactionID >> 8)
        response[1] = UInt8(transactionID & 0xff)
        response[2] = 0x81
        response[3] = 0x80 | (responseCode & 0x0f)
        response[6] = 0
        response[7] = address == nil ? 0 : 1
        guard let address else { return response }
        response.append(contentsOf: [
            0xc0, 0x0c, // Compressed owner name pointing to the question.
            0x00, 0x01, // A.
            0x00, 0x01, // IN.
            0x00, 0x00, 0x00, 0x3c, // TTL.
            0x00, 0x04,
        ])
        response.append(contentsOf: address)
        return response
    }

    private func chinaBypassConfiguration() -> [String: Any] {
        SingBoxConfiguration(
            relay: makeWssTestRelay(),
            splitTunnel: SplitTunnelRules(
                bypassLan: false,
                bypassCountries: ["cn"],
                ruleSetDirectory: "/var/rulesets"
            )
        ).makeJSONObject()
    }
}

private final class FakeThroughTunnelTransport: ThroughTunnelProbeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var dnsResponses: [Result<Void, Error>]
    private var responses: [Result<Data, Error>]
    private var storedHosts: [String] = []
    private var storedEndpoints: [TunnelProbeEndpoint] = []

    init(
        dnsResponses: [Result<Void, Error>] = [],
        responses: [Result<Data, Error>]
    ) {
        self.dnsResponses = dnsResponses
        self.responses = responses
    }

    func resolveFreshA(host: String) async throws {
        let response: Result<Void, Error>? = lock.withLock {
            storedHosts.append(host)
            return dnsResponses.isEmpty ? nil : dnsResponses.removeFirst()
        }
        try response?.get()
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

    var resolvedHosts: [String] {
        lock.withLock { storedHosts }
    }
}

private enum SimulatedProbePath: Equatable {
    case direct
    case proxy
}

/// Small generated-config integration harness. It deliberately treats the connectivity host as if
/// geosite-cn contains it; the first matching exact-host DNS and route rules must still win. This
/// reproduces the dangerous environment: usable direct internet can answer the request, while a
/// dead proxy must keep the startup handoff closed.
private final class RoutingAwareProbeTransport: ThroughTunnelProbeTransport, @unchecked Sendable {
    private let configuration: [String: Any]
    private let directInternetAvailable: Bool
    private let proxyAvailable: Bool
    private let lock = NSLock()
    private var storedPaths: [SimulatedProbePath] = []

    init(
        configuration: [String: Any],
        directInternetAvailable: Bool,
        proxyAvailable: Bool
    ) {
        self.configuration = configuration
        self.directInternetAvailable = directInternetAvailable
        self.proxyAvailable = proxyAvailable
    }

    func resolveFreshA(host: String) async throws {
        let path = selectedDNSPath(for: host)
        lock.withLock { storedPaths.append(path) }
        let available = path == .proxy ? proxyAvailable : directInternetAvailable
        guard available else { throw URLError(.cannotConnectToHost) }
    }

    func responseHead(for endpoint: TunnelProbeEndpoint) async throws -> Data {
        let path = selectedHTTPSPath(for: endpoint.host)
        lock.withLock { storedPaths.append(path) }
        let available = path == .proxy ? proxyAvailable : directInternetAvailable
        guard available else { throw URLError(.cannotConnectToHost) }
        return Data("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n".utf8)
    }

    var selectedPaths: [SimulatedProbePath] {
        lock.withLock { storedPaths }
    }

    private func selectedDNSPath(for host: String) -> SimulatedProbePath {
        guard
            let dns = configuration["dns"] as? [String: Any],
            let rules = dns["rules"] as? [[String: Any]]
        else { return .direct }
        for rule in rules {
            if let domains = rule["domain"] as? [String], domains.contains(host) {
                let server = rule["server"] as? String ?? ""
                if server.hasPrefix("dns-proxy-") { return .proxy }
            }
            if let sets = rule["rule_set"] as? [String], sets.contains("geosite-cn") {
                return .direct
            }
        }
        return .direct
    }

    private func selectedHTTPSPath(for host: String) -> SimulatedProbePath {
        guard
            let route = configuration["route"] as? [String: Any],
            let rules = route["rules"] as? [[String: Any]]
        else { return .direct }
        for rule in rules {
            if let domains = rule["domain"] as? [String], domains.contains(host) {
                return rule["outbound"] as? String == "proxy" ? .proxy : .direct
            }
            if let sets = rule["rule_set"] as? [String], sets.contains("geosite-cn") {
                return .direct
            }
        }
        return route["final"] as? String == "proxy" ? .proxy : .direct
    }
}
