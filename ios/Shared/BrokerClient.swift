import Foundation

/// A successful relay fetch together with the broker endpoint that won brokerapi's native race.
public struct BrokerFetch: Sendable {
    public let brokerURL: URL
    public let response: RelayListResponse

    public init(brokerURL: URL, response: RelayListResponse) {
        self.brokerURL = brokerURL
        self.response = response
    }
}

/// Thin Swift projection of brokerapi discovery. Candidate selection, custom-override policy,
/// staggered racing, redirect refusal, signature verification, and ECH transport selection all
/// remain inside the merged Go binding.
public enum BrokerClient {
    public static func firstReachable(
        primary: URL,
        limit: Int = 5,
        clientID: String? = nil,
        sessionID: String? = nil,
        operationFactory: any NativeBrokerOperationFactory
    ) async throws -> BrokerFetch {
        guard let nativeLimit = Int32(exactly: limit) else {
            throw BrokerNativeFailure(
                kind: .validation,
                message: "The relay-list limit is outside the native binding range."
            )
        }

        let result: NativeBrokerRelayResultSnapshot = try await NativeBrokerRunner.run(
            factory: operationFactory
        ) { operation in
            operation.firstReachable(
                primary: primary.absoluteString,
                limit: nativeLimit,
                clientID: clientID ?? "",
                sessionID: sessionID ?? ""
            )
        }
        try result.throwIfFailed()

        guard
            result.brokerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            let winningURL = URL(string: result.brokerURL),
            winningURL.scheme != nil
        else {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The native broker result contained an invalid winning URL."
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response: RelayListResponse
        do {
            // Decode the verified bytes exactly once. Decoder errors are deliberately discarded:
            // they can quote attacker-controlled response fields and are not remote diagnostics.
            response = try decoder.decode(
                RelayListResponse.self,
                from: Data(result.relayJSON.utf8)
            )
        } catch {
            throw BrokerNativeFailure(
                kind: .decode,
                message: "The verified relay list is incompatible with this app version."
            )
        }
        return BrokerFetch(brokerURL: winningURL, response: response)
    }
}
