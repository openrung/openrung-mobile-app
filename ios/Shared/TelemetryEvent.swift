import Foundation

/// Telemetry event matching the broker's schema. Port of Android `TelemetryEvent`
/// (snake_case JSON keys, `schema_version` = 1).
public struct TelemetryEvent: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var eventId: String
    public var event: String
    public var occurredAt: String
    public var clientId: String
    public var sessionId: String
    public var relayId: String?
    public var applicationPackage: String?
    public var applicationUid: Int?
    // destination_ip/destination_port/protocol were removed from the schema on purpose: the
    // broker discards them, and pairing the client with every destination visited is a privacy
    // hazard. Do not reintroduce them (see Android `TelemetryEvent`).
    public var attributes: [String: String]
    public var measurements: [String: Int64]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventId = "event_id"
        case event
        case occurredAt = "occurred_at"
        case clientId = "client_id"
        case sessionId = "session_id"
        case relayId = "relay_id"
        case applicationPackage = "application_package"
        case applicationUid = "application_uid"
        case attributes
        case measurements
    }

    public init(
        schemaVersion: Int = 1,
        eventId: String,
        event: String,
        occurredAt: String,
        clientId: String,
        sessionId: String,
        relayId: String? = nil,
        applicationPackage: String? = nil,
        applicationUid: Int? = nil,
        attributes: [String: String] = [:],
        measurements: [String: Int64] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.eventId = eventId
        self.event = event
        self.occurredAt = occurredAt
        self.clientId = clientId
        self.sessionId = sessionId
        self.relayId = relayId
        self.applicationPackage = applicationPackage
        self.applicationUid = applicationUid
        self.attributes = attributes
        self.measurements = measurements
    }
}

public struct TelemetryBatch: Codable, Sendable {
    public let events: [TelemetryEvent]

    public init(events: [TelemetryEvent]) {
        self.events = events
    }
}
