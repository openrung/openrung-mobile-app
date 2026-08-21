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
    fronts: [WssFrontDescriptor] = wssTestFronts,
    punchCapable: Bool = false,
    punchEndpoint: String = ""
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
        punchCapable: punchCapable,
        punchEndpoint: punchEndpoint,
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

/// The sing-box binding fixtures shared by the platform suites and `android/punchbridge`'s Go
/// tests: one `<scenario>.input.json` per platform scenario (the binding input the assembly must
/// produce), and one frozen `<scenario>.golden.json` holding the bound builder's output. The Go
/// suite is the only writer of the goldens and pins input→config through the real binding; the
/// suites here pin platform state→input and re-run this platform's structural emission assertions
/// against the goldens — so the existing expectations hold against the bound output without this
/// pod-free test bundle loading the engine. Lives in this file because the OpenRungTests target
/// lists files explicitly (xcodegen); adding a file means regenerating the project.
enum SingBoxBindingFixtures {
    /// Resolved from this file's own path, like the contract-vector suites, so the fixtures stay
    /// plain checked-in files and the Xcode target needs no resource wiring.
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // OpenRungTests
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("testdata/singbox-binding", isDirectory: true)

    static func input(_ scenario: String) throws -> [String: Any] {
        try object(file: "\(scenario).input.json")
    }

    static func golden(_ scenario: String) throws -> [String: Any] {
        try object(file: "\(scenario).golden.json")
    }

    static func goldenText(_ scenario: String) throws -> String {
        try String(contentsOf: directory.appendingPathComponent("\(scenario).golden.json"), encoding: .utf8)
    }

    /// Scenario names for this platform, derived from the checked-in input files.
    static func scenarios(platform: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("\(platform)-") && $0.hasSuffix(".input.json") }
            .map { String($0.dropLast(".input.json".count)) }
            .sorted()
    }

    /// The relay every scenario input carries. The connection identity fields must match the
    /// fixtures' `relay` object byte-for-byte; the remaining fields exist only to satisfy the
    /// model and are never assembled into the binding input.
    static func relay() -> RelayDescriptor {
        RelayDescriptor(
            id: "relay-1",
            publicHost: "203.0.113.10",
            publicPort: 443,
            relayProtocol: "vless-reality-vision",
            clientID: "e6b1a1de-9f0f-4c1a-8bb1-1f2b3c4d5e6f",
            realityPublicKey: "reality-key",
            shortID: "abcd1234",
            serverName: "www.example.com",
            flow: "xtls-rprx-vision",
            exitMode: "direct",
            maxSessions: 8,
            maxMbps: 100,
            relayVersion: "1.0.0",
            nodeClass: RelayConstants.nodeClassFoundation,
            transport: "tunnel",
            wssFronts: [],
            punchCapable: true,
            punchEndpoint: "https://203.0.113.10:9444",
            registeredAt: Date(timeIntervalSince1970: 1_767_225_600),
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_767_225_600),
            expiresAt: Date(timeIntervalSince1970: 1_798_761_600)
        )
    }

    private static func object(file: String) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(file))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "SingBoxBindingFixtures",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(file) is not a JSON object"]
            )
        }
        return object
    }
}
