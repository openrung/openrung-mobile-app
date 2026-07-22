import Foundation

public enum RelayConstants {
    public static let protocolVLESSRealityVision = "vless-reality-vision"
    public static let flowVision = "xtls-rprx-vision"
    public static let exitModeDirect = "direct"
    public static let transportDirect = "direct"
    public static let nodeClassFoundation = "foundation"
    public static let nodeClassVolunteer = "volunteer"
}

/// One canonical WSS/CDN front from the broker-signed relay descriptor.
public struct WssFrontDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let url: String
    public let protocolVersion: Int

    public init(id: String, url: String, protocolVersion: Int) {
        self.id = id
        self.url = url
        self.protocolVersion = protocolVersion
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case url
        case protocolVersion = "protocol_version"
    }

    /// Reject nested schema extensions before typed decoding can erase them. Top-level relay
    /// descriptors remain forward-compatible, but every signed front must exactly match wsscore.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        let unknown = raw.allKeys.map(\.stringValue).filter { allowed.contains($0) == false }
        guard unknown.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "WSS front contains unknown fields: \(unknown.sorted())"
                )
            )
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        url = try values.decode(String.self, forKey: .url)
        protocolVersion = try values.decode(Int.self, forKey: .protocolVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(url, forKey: .url)
        try values.encode(protocolVersion, forKey: .protocolVersion)
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}

public struct RelayDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// Friendly relay name (operator-supplied or generated); absent on older brokers.
    public let label: String?
    public let publicHost: String
    public let publicPort: Int
    public let relayProtocol: String
    public let clientID: String
    public let realityPublicKey: String
    public let shortID: String
    public let serverName: String
    public let flow: String
    public let exitMode: String
    public let maxSessions: Int
    public let maxMbps: Int
    /// Software version for any relay class; coding key preserves the legacy broker wire field.
    public let relayVersion: String
    /// Broker-attested trust class. Descriptors predating this field are volunteer relays.
    public let nodeClass: String
    /// Empty on legacy descriptors; otherwise "direct" or "tunnel".
    public let transport: String
    /// Exact canonical WSS fronts covered by the relay-list signature.
    public let wssFronts: [WssFrontDescriptor]
    public let registeredAt: Date
    public let lastHeartbeatAt: Date
    public let expiresAt: Date
    /// Broker-served exit location, absent until the broker's geo lookup succeeds (older brokers
    /// never send it). For tunnel (CGNAT) relays this is where traffic actually exits, which is
    /// NOT `publicHost` (the relay hub) — never geolocate `publicHost` client-side.
    public let city: String?
    public let country: String?
    public let countryCode: String?
    public let latitude: Double?
    public let longitude: Double?

    public init(
        id: String,
        label: String? = nil,
        publicHost: String,
        publicPort: Int,
        relayProtocol: String,
        clientID: String,
        realityPublicKey: String,
        shortID: String,
        serverName: String,
        flow: String,
        exitMode: String,
        maxSessions: Int,
        maxMbps: Int,
        relayVersion: String,
        nodeClass: String = RelayConstants.nodeClassVolunteer,
        transport: String = "",
        wssFronts: [WssFrontDescriptor] = [],
        registeredAt: Date,
        lastHeartbeatAt: Date,
        expiresAt: Date,
        city: String? = nil,
        country: String? = nil,
        countryCode: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil
    ) {
        self.id = id
        self.label = label
        self.publicHost = publicHost
        self.publicPort = publicPort
        self.relayProtocol = relayProtocol
        self.clientID = clientID
        self.realityPublicKey = realityPublicKey
        self.shortID = shortID
        self.serverName = serverName
        self.flow = flow
        self.exitMode = exitMode
        self.maxSessions = maxSessions
        self.maxMbps = maxMbps
        self.relayVersion = relayVersion
        self.nodeClass = nodeClass
        self.transport = transport
        self.wssFronts = wssFronts
        self.registeredAt = registeredAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.expiresAt = expiresAt
        self.city = city
        self.country = country
        self.countryCode = countryCode
        self.latitude = latitude
        self.longitude = longitude
    }

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case publicHost = "public_host"
        case publicPort = "public_port"
        case relayProtocol = "protocol"
        case clientID = "client_id"
        case realityPublicKey = "reality_public_key"
        case shortID = "short_id"
        case serverName = "server_name"
        case flow
        case exitMode = "exit_mode"
        case maxSessions = "max_sessions"
        case maxMbps = "max_mbps"
        case relayVersion = "volunteer_version"
        case nodeClass = "node_class"
        case transport
        case wssFronts = "wss_fronts"
        case registeredAt = "registered_at"
        case lastHeartbeatAt = "last_heartbeat_at"
        case expiresAt = "expires_at"
        case city
        case country
        case countryCode = "country_code"
        case latitude
        case longitude
    }

    /// Explicit tolerant decoder: Swift's synthesized Decodable does not apply initializer defaults
    /// when a non-optional key is absent. Defaults here keep legacy signed descriptors direct-only.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        publicHost = try values.decode(String.self, forKey: .publicHost)
        publicPort = try values.decode(Int.self, forKey: .publicPort)
        relayProtocol = try values.decode(String.self, forKey: .relayProtocol)
        clientID = try values.decode(String.self, forKey: .clientID)
        realityPublicKey = try values.decode(String.self, forKey: .realityPublicKey)
        shortID = try values.decode(String.self, forKey: .shortID)
        serverName = try values.decode(String.self, forKey: .serverName)
        flow = try values.decode(String.self, forKey: .flow)
        exitMode = try values.decode(String.self, forKey: .exitMode)
        maxSessions = try values.decode(Int.self, forKey: .maxSessions)
        maxMbps = try values.decode(Int.self, forKey: .maxMbps)
        relayVersion = try values.decode(String.self, forKey: .relayVersion)
        nodeClass = try values.decodeIfPresent(String.self, forKey: .nodeClass)
            ?? RelayConstants.nodeClassVolunteer
        transport = try values.decodeIfPresent(String.self, forKey: .transport) ?? ""
        wssFronts = try values.decodeIfPresent([WssFrontDescriptor].self, forKey: .wssFronts) ?? []
        registeredAt = try values.decode(Date.self, forKey: .registeredAt)
        lastHeartbeatAt = try values.decode(Date.self, forKey: .lastHeartbeatAt)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
        city = try values.decodeIfPresent(String.self, forKey: .city)
        country = try values.decodeIfPresent(String.self, forKey: .country)
        countryCode = try values.decodeIfPresent(String.self, forKey: .countryCode)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
    }
}

public struct RelayListResponse: Decodable, Equatable, Sendable {
    public let count: Int
    public let serverTime: Date
    public let relays: [RelayDescriptor]

    enum CodingKeys: String, CodingKey {
        case count
        case serverTime = "server_time"
        case relays
    }
}

public extension RelayDescriptor {
    func isUsable(now: Date = Date()) -> Bool {
        relayProtocol == RelayConstants.protocolVLESSRealityVision &&
            flow == RelayConstants.flowVision &&
            exitMode == RelayConstants.exitModeDirect &&
            expiresAt > now &&
            publicHost.isEmpty == false &&
            publicPort > 0 &&
            clientID.isEmpty == false &&
            realityPublicKey.isEmpty == false &&
            shortID.isEmpty == false &&
            serverName.isEmpty == false
    }

    /// Human-readable exit location such as "Tokyo, Japan", or "" while the broker has no geo.
    func locationLabel() -> String {
        [city, country].compactMap { $0 }.filter { $0.isEmpty == false }.joined(separator: ", ")
    }
}
