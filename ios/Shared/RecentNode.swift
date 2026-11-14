import Foundation

/// A location the user has previously connected through, shown in the main-screen "Recents" row.
public struct RecentNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String { relayId ?? countryCode }

    public let countryCode: String
    /// Exact broker relay id; nil on entries saved by older builds.
    public let relayId: String?
    public let label: String
    /// Friendly broker label, falling back to relay id; nil on entries saved by older builds.
    public let relayName: String?
    public let latitude: Double
    public let longitude: Double

    public init(
        countryCode: String,
        relayId: String?,
        label: String,
        relayName: String?,
        latitude: Double,
        longitude: Double
    ) {
        self.countryCode = countryCode
        self.relayId = relayId
        self.label = label
        self.relayName = relayName
        self.latitude = latitude
        self.longitude = longitude
    }
}
