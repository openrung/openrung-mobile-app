import Foundation

/// Credential-free state mapping. Expectations derive from the shipping RN
/// contract; no native connection policy is inferred from notices or logs.
struct EngineStateProjection {
    let status: ConnectionStatus
    let sessionID: String?
    let location: String?
    let relayName: String?
    let relayClass: String?
    let error: String?
    let recent: RecentNode?

    init?(_ event: EngineEvent) {
        guard let status = event.status else { return nil }
        self.status = status
        let payload = event.payload
        let details = payload["Details"] as? [String: Any] ?? [:]
        sessionID = (details["SessionID"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        error = payload["LastError"] as? String
        guard status == .connected else {
            location = nil; relayName = nil; relayClass = nil; recent = nil
            return
        }
        let id = details["RelayID"] as? String ?? ""
        let rawName = details["RelayName"] as? String ?? ""
        // connectcore uses the full ID when the signed label is empty.
        relayName = RelayDescriptor.displayName(rawName == id ? nil : rawName, id: id)
        relayClass = details["RelayClass"] as? String == "foundation" ? "foundation" : "volunteer"
        let label = RelayDescriptor.sanitizeDisplayName(details["LocationLabel"] as? String ?? "", maxCodePoints: 128)
        location = label.isEmpty ? "Unknown location" : label
        if let row = (payload["Recents"] as? [[String: Any]])?.first, row["RelayID"] as? String == id {
            recent = RecentNode(countryCode: row["CountryCode"] as? String ?? "", relayId: id,
                label: location!, relayName: relayName,
                latitude: row["Latitude"] as? Double ?? 0, longitude: row["Longitude"] as? Double ?? 0)
        } else { recent = nil }
    }
}

extension ConnectionStateSnapshot {
    mutating func applyEngineState(_ state: EngineStateProjection) {
        self.status = state.status
        self.sessionID = [.disconnected, .failed].contains(state.status) ? nil : state.sessionID
        self.relayLabel = state.location
        self.relayName = state.relayName
        self.relayClass = state.relayClass
        self.lastError = state.error
        if let node = state.recent { recordRecent(node) }
    }

    /// Most recent first, deduped by relay ID. Like Android, nil or blank IDs
    /// identify legacy country entries, replaced by a new relay in that country.
    mutating func recordRecent(_ node: RecentNode) {
        recentRegions = Array(([node] + recentRegions.filter {
            let legacy = $0.relayId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            return $0.relayId != node.relayId && !(legacy && $0.countryCode == node.countryCode)
        }).prefix(AppConfig.maxRecents))
    }
}
