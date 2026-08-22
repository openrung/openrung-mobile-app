import Foundation

// Production convenience points live with the Libbox adapter so none of the pure client source
// files needs a Libbox-referencing default argument. Kept apart from
// LibboxBrokerTransport.swift so the app target (which only needs the React Native factory)
// does not have to compile BrokerClient/WssTicketClient and their source closure; only the
// PacketTunnel extension and the test bundle use these entry points.
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
