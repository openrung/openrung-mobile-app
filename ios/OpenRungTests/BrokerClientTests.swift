import Foundation
import XCTest

final class BrokerClientTests: XCTestCase {
    private let primary = URL(string: "https://custom.example/base/")!
    private let winner = URL(string: "https://winner.example/")!
    private let relayJSON = """
    {"count":0,"server_time":"2026-07-26T00:00:00Z","relays":[]}
    """

    func testDiscoveryForwardsPrimaryLimitAndPairedIdentityAndRetainsWinner() async throws {
        struct Invocation: Equatable {
            let primary: String
            let limit: Int32
            let clientID: String
            let sessionID: String
        }
        let invocation = TestLockedBox<Invocation?>(nil)
        let operation = TestNativeBrokerOperation()
        operation.relayHandler = { [winner, relayJSON] value, limit, clientID, sessionID in
            invocation.set(
                Invocation(
                    primary: value,
                    limit: limit,
                    clientID: clientID,
                    sessionID: sessionID
                )
            )
            return NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: winner.absoluteString,
                relayJSON: relayJSON,
                keyID: "key-a",
                signatureVerified: true
            )
        }

        let fetch = try await BrokerClient.firstReachable(
            primary: primary,
            limit: 20,
            clientID: "client-a",
            sessionID: "session-a",
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )

        XCTAssertEqual(
            invocation.get(),
            Invocation(
                primary: primary.absoluteString,
                limit: 20,
                clientID: "client-a",
                sessionID: "session-a"
            )
        )
        XCTAssertEqual(fetch.brokerURL, winner)
        XCTAssertEqual(fetch.response.count, 0)
        XCTAssertEqual(fetch.response.relays, [])
        XCTAssertEqual(operation.closeCount, 1)
    }

    func testAbsentIdentityIsForwardedAsEmptyStrings() async throws {
        let invocation = TestLockedBox<(String, String)?>(nil)
        let operation = TestNativeBrokerOperation()
        operation.relayHandler = { [winner, relayJSON] _, _, clientID, sessionID in
            invocation.set((clientID, sessionID))
            return NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: winner.absoluteString,
                relayJSON: relayJSON
            )
        }

        _ = try await BrokerClient.firstReachable(
            primary: primary,
            operationFactory: TestNativeBrokerFactory(operation: operation)
        )

        XCTAssertEqual(invocation.get()?.0, "")
        XCTAssertEqual(invocation.get()?.1, "")
    }

    func testMalformedVerifiedRelayJSONIsALocalDecodeFailureWithoutAnotherOperation() async {
        let operation = TestNativeBrokerOperation()
        operation.relayHandler = { [winner] _, _, _, _ in
            NativeBrokerRelayResultSnapshot(
                succeeded: true,
                brokerURL: winner.absoluteString,
                relayJSON: #"{"count":"wrong"}"#
            )
        }
        let factory = TestNativeBrokerFactory(operation: operation)

        do {
            _ = try await BrokerClient.firstReachable(
                primary: primary,
                operationFactory: factory
            )
            XCTFail("expected relay decode failure")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .decode)
            XCTAssertTrue(failure.isLocalPlatformFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(factory.makeCount, 1)
        XCTAssertEqual(operation.closeCount, 1)
    }

    func testNilNativeOperationIsUnavailableWithNoHTTPFallback() async {
        let factory = TestNativeBrokerFactory(operation: nil)
        do {
            _ = try await BrokerClient.firstReachable(
                primary: primary,
                operationFactory: factory
            )
            XCTFail("expected unavailable failure")
        } catch let failure as BrokerNativeFailure {
            XCTAssertEqual(failure.kind, .unavailable)
            XCTAssertTrue(failure.isLocalPlatformFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(factory.makeCount, 1)
    }
}
