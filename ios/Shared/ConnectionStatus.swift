import Foundation

/// Connection lifecycle states. Port of Android `ConnectionStatus`.
public enum ConnectionStatus: String, Codable, Sendable, CaseIterable {
    case disconnected
    case preparing
    case connecting
    case connected
    case disconnecting
    case failed

    public var isWorking: Bool {
        self == .preparing || self == .connecting || self == .disconnecting
    }

    public var isConnected: Bool {
        self == .connected
    }

    /// Default English label (matches Android `status_*` strings).
    public var displayLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .preparing: return "Preparing VPN"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .disconnecting: return "Disconnecting"
        case .failed: return "Failed"
        }
    }
}

/// The connection UI state shared between the PacketTunnel extension (writer) and the app (reader).
/// Port of Android `OpenRungUiState`.
public struct ConnectionStateSnapshot: Codable, Sendable, Equatable {
    public var status: ConnectionStatus
    public var brokerURL: String
    public var relayLabel: String?
    public var relayName: String?
    /// Node class of the connected relay ("foundation" / "volunteer"); follows relayName's
    /// lifecycle exactly (set on connect, cleared everywhere relayName is cleared).
    public var relayClass: String?
    public var lastError: String?
    public var logLines: [String]
    public var recentRegions: [RecentNode]

    public init(
        status: ConnectionStatus = .disconnected,
        brokerURL: String = "",
        relayLabel: String? = nil,
        relayName: String? = nil,
        relayClass: String? = nil,
        lastError: String? = nil,
        logLines: [String] = [],
        recentRegions: [RecentNode] = []
    ) {
        self.status = status
        self.brokerURL = brokerURL
        self.relayLabel = relayLabel
        self.relayName = relayName
        self.relayClass = relayClass
        self.lastError = lastError
        self.logLines = logLines
        self.recentRegions = recentRegions
    }

    public var isWorking: Bool { status.isWorking }
    public var isConnected: Bool { status.isConnected }

    enum CodingKeys: String, CodingKey {
        case status
        case brokerURL
        case relayLabel
        case relayName
        case relayClass
        case lastError
        case logLines
        case recentRegions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(ConnectionStatus.self, forKey: .status) ?? .disconnected
        brokerURL = try container.decodeIfPresent(String.self, forKey: .brokerURL) ?? ""
        relayLabel = try container.decodeIfPresent(String.self, forKey: .relayLabel)
        relayName = try container.decodeIfPresent(String.self, forKey: .relayName)
        relayClass = try container.decodeIfPresent(String.self, forKey: .relayClass)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        logLines = try container.decodeIfPresent([String].self, forKey: .logLines) ?? []
        recentRegions = try container.decodeIfPresent([RecentNode].self, forKey: .recentRegions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(brokerURL, forKey: .brokerURL)
        try container.encodeIfPresent(relayLabel, forKey: .relayLabel)
        try container.encodeIfPresent(relayName, forKey: .relayName)
        try container.encodeIfPresent(relayClass, forKey: .relayClass)
        try container.encodeIfPresent(lastError, forKey: .lastError)
        try container.encode(logLines, forKey: .logLines)
        try container.encode(recentRegions, forKey: .recentRegions)
    }
}

// MARK: - Pure state transitions
//
// The transition rules `SharedConnectionState` persists, kept on the snapshot itself so the
// lifecycle (keep-while-connected / clear-otherwise, failure clearing, cold-start sanitizing)
// is unit-testable without the app-group store.
extension ConnectionStateSnapshot {
    /// The status/relay-identity rule behind `SharedConnectionState.setStatus`: while connected,
    /// nil keeps the current relay name/class (mirroring the Android store's defaults) so a
    /// mid-session status re-assert never blanks the UI; every other status always clears both.
    public mutating func apply(
        status: ConnectionStatus,
        relayName: String? = nil,
        relayClass: String? = nil,
        clearRelayLabel: Bool = false,
        clearError: Bool = false
    ) {
        self.status = status
        self.relayName = status == .connected ? (relayName ?? self.relayName) : nil
        self.relayClass = status == .connected ? (relayClass ?? self.relayClass) : nil
        if clearRelayLabel { relayLabel = nil }
        if clearError { lastError = nil }
    }

    /// The terminal-failure rule behind `SharedConnectionState.fail`: relay identity (label,
    /// name, class) never survives a failure.
    public mutating func applyFailure(_ message: String) {
        status = .failed
        lastError = message
        relayLabel = nil
        relayName = nil
        relayClass = nil
    }

    /// What the app may show on a cold launch: a stale CONNECTED never survives, and relay
    /// details (which could leak a prior relay) are dropped until re-resolved.
    public func sanitizedForColdStart() -> ConnectionStateSnapshot {
        var snapshot = self
        if snapshot.status == .connected {
            snapshot.status = .disconnected
        }
        snapshot.relayLabel = nil
        snapshot.relayName = nil
        snapshot.relayClass = nil
        return snapshot
    }
}
