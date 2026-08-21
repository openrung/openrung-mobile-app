import Foundation
import Libbox

/// Production iOS factory. This is the only shared broker-adapter file that imports Libbox or
/// mentions generated broker types; the hostless test target deliberately excludes it.
public struct LibboxBrokerOperationFactory: NativeBrokerOperationFactory {
    private let factory: ConfiguredNativeBrokerOperationFactory

    public init() {
        factory = ConfiguredNativeBrokerOperationFactory(
            appVersion: DeviceAttributes.appVersion,
            client: .ios(osVersion: DeviceAttributes.osVersion),
            constructor: LibboxBrokerOperationConstructor()
        )
    }

    public func makeOperation() -> (any NativeBrokerOperation)? {
        factory.makeOperation()
    }
}

/// React Native requests use their own binding constructor and fixed one-platform token. The
/// PacketTunnel and native iOS clients continue to use `LibboxBrokerOperationFactory` above.
public struct LibboxReactNativeBrokerOperationFactory: NativeBrokerOperationFactory {
    private let factory: ConfiguredNativeBrokerOperationFactory

    public init() {
        factory = .forReactNativeIOS(
            appVersion: DeviceAttributes.appVersion,
            constructor: LibboxBrokerOperationConstructor()
        )
    }

    public func makeOperation() -> (any NativeBrokerOperation)? {
        factory.makeOperation()
    }
}

private struct LibboxBrokerOperationConstructor: NativeBrokerOperationConstructing {
    func makeIOSOperation(
        appVersion: String,
        osVersion: String
    ) -> (any NativeBrokerOperation)? {
        guard let operation = LibboxNewOpenRungBrokerOperationForIOS(
            appVersion,
            osVersion
        ) else {
            return nil
        }
        return LibboxBrokerOperation(operation: operation)
    }

    func makeReactNativeOperation(
        appVersion: String,
        osToken: String
    ) -> (any NativeBrokerOperation)? {
        guard let operation = LibboxNewOpenRungBrokerOperationForReactNative(
            appVersion,
            osToken
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

    func runSpeedTest(
        brokerURL: String
    ) -> NativeBrokerSpeedTestResultSnapshot? {
        guard let result = operation.runSpeedTest(brokerURL) else {
            return nil
        }
        return NativeBrokerSpeedTestResultSnapshot(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis(),
            bytes: result.bytes(),
            timeToFirstByteMilliseconds: result.ttfbMillis(),
            downloadDurationMilliseconds: result.downloadDurationMillis(),
            totalDurationMilliseconds: result.totalDurationMillis(),
            megabitsPerSecond: result.mbps()
        )
    }

    func fetchManifestCandidate(
        candidateURL: String
    ) -> NativeBrokerManifestResultSnapshot? {
        guard let result = operation.fetchManifestCandidate(candidateURL) else {
            return nil
        }
        return NativeBrokerManifestResultSnapshot(
            succeeded: result.succeeded(),
            errorKind: result.errorKind(),
            errorText: result.errorText(),
            httpStatus: result.httpStatus(),
            retryAfterMilliseconds: result.retryAfterMillis(),
            bodyJSON: result.bodyJSON(),
            sourceURL: result.sourceURL()
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
