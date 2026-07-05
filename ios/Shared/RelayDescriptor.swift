import Foundation

public enum RelayConstants {
    public static let protocolVLESSRealityVision = "vless-reality-vision"
    public static let flowVision = "xtls-rprx-vision"
    public static let exitModeDirect = "direct"
}

public struct RelayDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    /// Volunteer-chosen relay name (e.g. "silly-lemur"); absent on older brokers.
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
    public let volunteerVersion: String
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
        volunteerVersion: String,
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
        self.volunteerVersion = volunteerVersion
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
        case volunteerVersion = "volunteer_version"
        case registeredAt = "registered_at"
        case lastHeartbeatAt = "last_heartbeat_at"
        case expiresAt = "expires_at"
        case city
        case country
        case countryCode = "country_code"
        case latitude
        case longitude
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
