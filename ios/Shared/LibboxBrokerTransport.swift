import Foundation
import Libbox

/// Production iOS factory. This is the only shared broker-adapter file that imports Libbox or
/// mentions generated broker types; the hostless test target deliberately excludes it.
public struct LibboxBrokerOperationFactory: NativeBrokerOperationFactory {
    public init() {}

    public func makeOperation() -> (any NativeBrokerOperation)? {
        guard let operation = LibboxNewOpenRungBrokerOperationForIOS(
            DeviceAttributes.appVersion,
            DeviceAttributes.osVersion
        ) else {
            return nil
        }
        return LibboxBrokerOperation(operation: operation)
    }
}

/// A generated gomobile operation is not Sendable, but ownership is tightly scoped: one blocking
/// selector runs on one worker while cancellation may call the documented concurrent-safe `Close`.
private final class LibboxBrokerOperation: NativeBrokerOperation, @unchecked Sendable {
    private let operation: any LibboxOpenRungBrokerOperationProtocol

    init(operation: any LibboxOpenRungBrokerOperationProtocol) {
        self.operation = operation
    }

    func firstReachable(
        primary: String,
        limit: Int32,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerRelayResultSnapshot? {
        guard let result = operation.firstReachable(
            primary,
            limit: limit,
            clientID: clientID,
            sessionID: sessionID
        ) else {
            return nil
        }
        return NativeBrokerRelayResultSnapshot(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis(),
            brokerURL: result.brokerURL(),
            relayJSON: result.relayJSON(),
            keyID: result.keyID(),
            signatureVerified: result.signatureVerified()
        )
    }

    func sendTelemetryBatchJSON(
        brokerURL: String,
        batchJSON: String
    ) -> NativeBrokerResultSnapshot? {
        guard let result = operation.sendTelemetryBatchJSON(brokerURL, batchJSON: batchJSON) else {
            return nil
        }
        return NativeBrokerResultSnapshot(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis()
        )
    }

    func requestWSSTicket(
        brokerURL: String,
        relayID: String,
        frontID: String,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerWSSTicketResultSnapshot? {
        guard let result = operation.requestWSSTicket(
            brokerURL,
            relayID: relayID,
            frontID: frontID,
            clientID: clientID,
            sessionID: sessionID
        ) else {
            return nil
        }
        return NativeBrokerWSSTicketResultSnapshot(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis(),
            ticket: result.ticket(),
            url: result.url(),
            expiresAtMilliseconds: result.expiresAtMillis()
        )
    }

    func close() {
        operation.close()
    }
}

// Production convenience points live with the Libbox adapter so none of the pure client source
// files needs a Libbox-referencing default argument.
public extension BrokerClient {
    static func firstReachable(
        primary: URL,
        limit: Int = 5,
        clientID: String? = nil,
        sessionID: String? = nil
    ) async throws -> BrokerFetch {
        try await firstReachable(
            primary: primary,
            limit: limit,
            clientID: clientID,
            sessionID: sessionID,
            operationFactory: LibboxBrokerOperationFactory()
        )
    }
}

extension WssTicketClient {
    convenience init() {
        self.init(operationFactory: LibboxBrokerOperationFactory())
    }
}

public extension TelemetryClient {
    init(brokerURL: URL) throws {
        self.init(
            brokerURL: brokerURL,
            operationFactory: LibboxBrokerOperationFactory()
        )
    }
}
