import Foundation

let wssTestFronts = [
    WssFrontDescriptor(id: "front-a", url: "wss://a.cdn.example/connect", protocolVersion: 1),
    WssFrontDescriptor(id: "front-b", url: "wss://b.cdn.example/connect", protocolVersion: 1),
]

func makeWssTestRelay(
    id: String = "relay-wss",
    nodeClass: String = RelayConstants.nodeClassFoundation,
    transport: String = RelayConstants.transportDirect,
    exitMode: String = RelayConstants.exitModeDirect,
    publicPort: Int = 443,
    fronts: [WssFrontDescriptor] = wssTestFronts
) -> RelayDescriptor {
    RelayDescriptor(
        id: id,
        publicHost: "203.0.113.10",
        publicPort: publicPort,
        relayProtocol: RelayConstants.protocolVLESSRealityVision,
        clientID: "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
        realityPublicKey: "reality-public-key",
        shortID: "abcd",
        serverName: "www.example.com",
        flow: RelayConstants.flowVision,
        exitMode: exitMode,
        maxSessions: 8,
        maxMbps: 100,
        relayVersion: "1.0.0",
        nodeClass: nodeClass,
        transport: transport,
        wssFronts: fronts,
        registeredAt: Date(timeIntervalSince1970: 1_767_225_600),
        lastHeartbeatAt: Date(timeIntervalSince1970: 1_767_225_600),
        expiresAt: Date(timeIntervalSince1970: 1_798_761_600)
    )
}

actor WssTestEventLog {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] { values }
}
