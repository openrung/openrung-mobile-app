import Foundation
import React

/// Dedicated classic React Native bridge for eligible direct broker requests.
///
/// WSS ticket operations intentionally remain absent: credentials are owned only by the
/// PacketTunnel provider and never cross the React Native bridge.
@objc(OpenRungBroker)
final class OpenRungBrokerModule: NSObject, RCTInvalidating {
    private static let errorDomain = "com.openrung.app.OpenRungBroker"

    private let coordinator: OpenRungBrokerRequestCoordinator

    override init() {
        coordinator = OpenRungBrokerRequestCoordinator(
            operationFactory: LibboxReactNativeBrokerOperationFactory()
        )
        super.init()
    }

    deinit {
        coordinator.invalidate()
    }

    @objc
    static func requiresMainQueueSetup() -> Bool { false }

    @objc
    func invalidate() {
        coordinator.invalidate()
    }

    @objc(firstReachable:primary:limit:clientId:sessionId:resolver:rejecter:)
    func firstReachable(
        _ requestID: String,
        primary: String,
        limit: NSNumber,
        clientId: String,
        sessionId: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        coordinator.firstReachable(
            requestID: requestID,
            primary: primary,
            limit: limit.doubleValue,
            clientID: clientId,
            sessionID: sessionId
        ) { result in
            switch result {
            case .success(let snapshot):
                resolve([
                    "brokerUrl": snapshot.brokerURL,
                    "relayJson": snapshot.relayJSON,
                    "keyId": snapshot.keyID,
                    "signatureVerified": snapshot.signatureVerified,
                ] as [String: Any])
            case .failure(let failure):
                Self.reject(failure, using: reject)
            }
        }
    }

    @objc(runSpeedTest:brokerUrl:resolver:rejecter:)
    func runSpeedTest(
        _ requestID: String,
        brokerUrl: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        coordinator.runSpeedTest(
            requestID: requestID,
            brokerURL: brokerUrl
        ) { result in
            switch result {
            case .success(let snapshot):
                resolve([
                    "bytes": NSNumber(value: snapshot.bytes),
                    "ttfbMillis": NSNumber(value: snapshot.timeToFirstByteMilliseconds),
                    "downloadDurationMillis": NSNumber(
                        value: snapshot.downloadDurationMilliseconds
                    ),
                    "totalDurationMillis": NSNumber(value: snapshot.totalDurationMilliseconds),
                    "mbps": NSNumber(value: snapshot.megabitsPerSecond),
                ] as [String: Any])
            case .failure(let failure):
                Self.reject(failure, using: reject)
            }
        }
    }

    @objc(sendTelemetryBatchJSON:brokerUrl:batchJson:resolver:rejecter:)
    func sendTelemetryBatchJSON(
        _ requestID: String,
        brokerUrl: String,
        batchJson: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        coordinator.sendTelemetryBatchJSON(
            requestID: requestID,
            brokerURL: brokerUrl,
            batchJSON: batchJson
        ) { result in
            switch result {
            case .success:
                resolve([String: Any]())
            case .failure(let failure):
                Self.reject(failure, using: reject)
            }
        }
    }

    @objc(fetchManifestCandidate:candidateUrl:resolver:rejecter:)
    func fetchManifestCandidate(
        _ requestID: String,
        candidateUrl: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        coordinator.fetchManifestCandidate(
            requestID: requestID,
            candidateURL: candidateUrl
        ) { result in
            switch result {
            case .success(let snapshot):
                resolve([
                    "bodyJson": snapshot.bodyJSON,
                    "sourceUrl": snapshot.sourceURL,
                ] as [String: Any])
            case .failure(let failure):
                Self.reject(failure, using: reject)
            }
        }
    }

    @objc(cancel:resolver:rejecter:)
    func cancel(
        _ requestID: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter _: @escaping RCTPromiseRejectBlock
    ) {
        resolve(coordinator.cancel(requestID: requestID))
    }

    private static func reject(
        _ failure: BrokerNativeFailure,
        using reject: RCTPromiseRejectBlock
    ) {
        let message = failure.errorDescription
            ?? "The native broker request failed (\(failure.kind.rawValue))."
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: message,
            "message": message,
            "kind": failure.kind.rawValue,
        ]
        if let httpStatus = failure.httpStatus {
            userInfo["httpStatus"] = httpStatus
        }
        if let retryAfterMilliseconds = failure.retryAfterMilliseconds {
            userInfo["retryAfterMillis"] = NSNumber(value: retryAfterMilliseconds)
        }
        let error = NSError(
            domain: errorDomain,
            code: failure.httpStatus ?? 0,
            userInfo: userInfo
        )
        reject(failure.kind.rawValue, message, error)
    }
}
