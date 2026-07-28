import Foundation
import XCTest

final class PunchNativeClientTests: XCTestCase {
    func testDescriptorDecodesSignedPunchMetadataAndDefaultsLegacyFields() throws {
        let advertised = makePunchRelay()
        let encoded = try JSONEncoder().encode(advertised)
        let decoded = try JSONDecoder().decode(RelayDescriptor.self, from: encoded)
        XCTAssertTrue(decoded.punchCapable)
        XCTAssertEqual(decoded.punchEndpoint, "https://43.201.124.63:9444")

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "punch_capable")
        object.removeValue(forKey: "punch_endpoint")
        let legacy = try JSONDecoder().decode(
            RelayDescriptor.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertFalse(legacy.punchCapable)
        XCTAssertEqual(legacy.punchEndpoint, "")
    }

    func testPolicyAcceptsOnlyCapableRelayExplicitHTTPSAndTrimsTrailingSlashes() throws {
        let relay = makePunchRelay(endpoint: " https://43.201.124.63:9444/// ")
        let configuration = try XCTUnwrap(PunchCoordinatorPolicy.configuration(for: relay))

        XCTAssertEqual(configuration.baseURL, "https://43.201.124.63:9444")
        XCTAssertEqual(configuration.relayID, relay.id)
        XCTAssertTrue(configuration.tls.allowSelfSigned)
        XCTAssertEqual(
            configuration.tls.certificateSHA256,
            "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5"
        )

        XCTAssertNil(
            PunchCoordinatorPolicy.configuration(
                for: makePunchRelay(capable: false, endpoint: relay.punchEndpoint)
            )
        )
    }

    func testHostnameCoordinatorUsesOrdinaryCertificateValidation() throws {
        let configuration = try XCTUnwrap(
            PunchCoordinatorPolicy.configuration(
                for: makePunchRelay(endpoint: "https://hub.example.com/punch")
            )
        )
        XCTAssertFalse(configuration.tls.allowSelfSigned)
        XCTAssertEqual(configuration.tls.certificateSHA256, "")
    }

    func testPolicyRejectsUnsafeOrMalformedCoordinatorEndpoints() {
        let rejected = [
            "",
            "http://43.201.124.63:9444",
            "https://user@hub.example.com:9444",
            "https://user:password@hub.example.com:9444",
            "https://hub.example.com%40evil.example:9444",
            "https://hub.example.com\\@evil.example:9444",
            "https://hub.example.com:9444?next=http://evil",
            "https://hub.example.com:9444?",
            "https://hub.example.com:9444#fragment",
            "https://hub.example.com:0",
            "https://hub.example.com:65536",
            "https://hub.example.com:",
            "https://hub.example.com:not-a-port",
            "https://hub.example.com/a path",
            "not a url",
        ]

        for endpoint in rejected {
            XCTAssertNil(
                PunchCoordinatorPolicy.configuration(for: makePunchRelay(endpoint: endpoint)),
                "accepted unsafe coordinator endpoint: \(endpoint)"
            )
        }
    }

    func testBareIPCoordinatorRequiresAnExactEmbeddedPin() {
        let rejected = [
            "https://203.0.113.8:9444",
            "https://999.1.1.1:9444",
            "https://43.201.124.63.:9444",
            "https://[2001:db8::1]:9444",
        ]

        for endpoint in rejected {
            XCTAssertNil(
                PunchCoordinatorPolicy.configuration(for: makePunchRelay(endpoint: endpoint)),
                "accepted unpinned IP-like coordinator: \(endpoint)"
            )
        }

        let secondPinnedHost = PunchCoordinatorPolicy.configuration(
            for: makePunchRelay(endpoint: "https://43.201.172.102:9444")
        )
        XCTAssertEqual(
            secondPinnedHost?.tls.certificateSHA256,
            "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5"
        )
    }

    func testNativeResultRequiresALiteralLoopbackAddressAndValidPort() throws {
        let ipv4 = try PunchNativeResultValidator.validatedResult(
            bridgeHost: "127.255.0.1",
            bridgePort: 24_680,
            peerIP: "198.51.100.20",
            sessionID: "session-1",
            natClass: "eim",
            rttMillis: 42
        )
        XCTAssertEqual(ipv4.bridgeHost, "127.255.0.1")
        XCTAssertEqual(ipv4.bridgePort, 24_680)
        XCTAssertEqual(ipv4.peerIP, "198.51.100.20")
        XCTAssertEqual(ipv4.sessionID, "session-1")
        XCTAssertEqual(ipv4.natClass, "eim")
        XCTAssertEqual(ipv4.rttMillis, 42)

        XCTAssertNoThrow(
            try PunchNativeResultValidator.validatedResult(
                bridgeHost: "[::1]",
                bridgePort: 1,
                peerIP: "",
                sessionID: "",
                natClass: "",
                rttMillis: 0
            )
        )

        let invalidEndpoints: [(String, Int)] = [
            ("localhost", 24_680),
            ("126.255.0.1", 24_680),
            ("127.0.0.256", 24_680),
            ("[[::1]]", 24_680),
            ("::1", 0),
            ("127.0.0.1", 65_536),
        ]
        for (host, port) in invalidEndpoints {
            XCTAssertThrowsError(
                try PunchNativeResultValidator.validatedResult(
                    bridgeHost: host,
                    bridgePort: port,
                    peerIP: "",
                    sessionID: "",
                    natClass: "",
                    rttMillis: 0
                )
            ) { error in
                XCTAssertEqual(error as? PunchNativeClientError, .invalidLoopbackEndpoint)
            }
        }
    }

    func testNativeFailureReasonsMapToABoundedTaxonomy() {
        XCTAssertEqual(PunchNativeFailureReason(nativeReason: "config"), .configuration)
        XCTAssertEqual(PunchNativeFailureReason(nativeReason: "protect"), .socketProtection)
        XCTAssertEqual(PunchNativeFailureReason(nativeReason: "declined:relay busy"), .declined)
        XCTAssertEqual(PunchNativeFailureReason(nativeReason: "new-server-value"), .transport)

        let first = PunchNativeClientError.establishmentFailed(
            reason: PunchNativeFailureReason(nativeReason: "declined:secret-a"),
            detail: "remote detail a",
            natClass: "eim"
        )
        let second = PunchNativeClientError.establishmentFailed(
            reason: PunchNativeFailureReason(nativeReason: "declined:secret-b"),
            detail: "remote detail b",
            natClass: "eim"
        )
        XCTAssertEqual(first.failureReason, "punch_declined")
        XCTAssertEqual(second.failureReason, "punch_declined")
        XCTAssertFalse(first.localizedDescription.contains("remote detail"))
        XCTAssertEqual(
            PunchNativeClientError.establishmentFailed(
                reason: .transport,
                detail: "anything",
                natClass: ""
            ).failureReason,
            "punch_transport_failed"
        )
    }

    func testCloseGateRunsNativeCloseExactlyOnceAcrossRaces() {
        let gate = PunchNativeCloseGate()
        let countLock = NSLock()
        var closeCount = 0

        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            gate.runOnce {
                countLock.lock()
                closeCount += 1
                countLock.unlock()
            }
        }

        XCTAssertEqual(closeCount, 1)
    }

    func testUnexpectedCloseSignalSuppliesDefaultAndBoundsNativeText() async {
        let defaultSignal = PunchNativeCloseSignal()
        let defaultWait = Task {
            for await reason in defaultSignal.events { return reason }
            return "finished"
        }
        defaultSignal.reportUnexpectedClose(" ")
        let defaultReason = await defaultWait.value
        XCTAssertEqual(defaultReason, "direct QUIC path closed")

        let boundedSignal = PunchNativeCloseSignal()
        let boundedWait = Task {
            for await reason in boundedSignal.events { return reason }
            return "finished"
        }
        boundedSignal.reportUnexpectedClose(String(repeating: "x", count: 1_024))
        let boundedReason = await boundedWait.value
        XCTAssertEqual(boundedReason.count, 256)
    }

    #if !canImport(Libbox)
    func testUnavailableBuildStillSkipsInvalidMetadataBeforeReportingNativeUnavailable() throws {
        XCTAssertNil(
            try NativePunchSessionFactory.make(
                relay: makePunchRelay(capable: false)
            )
        )
        XCTAssertThrowsError(
            try NativePunchSessionFactory.make(relay: makePunchRelay())
        ) { error in
            XCTAssertEqual(error as? PunchNativeClientError, .unavailable)
        }
    }
    #endif

    private func makePunchRelay(
        capable: Bool = true,
        endpoint: String = "https://43.201.124.63:9444"
    ) -> RelayDescriptor {
        makeWssTestRelay(
            id: "relay-punch",
            transport: "tunnel",
            punchCapable: capable,
            punchEndpoint: endpoint
        )
    }
}
