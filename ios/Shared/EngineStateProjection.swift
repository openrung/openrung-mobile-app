import Foundation

/// Credential-free state mapping. Expectations derive from the shipping RN
/// contract; no native connection policy is inferred from notices or logs.
struct EngineStateProjection {
    let status: ConnectionStatus
    let sessionID: String?
    let relayID: String?
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
            relayID = nil; location = nil; relayName = nil; relayClass = nil; recent = nil
            return
        }
        let id = details["RelayID"] as? String ?? ""
        relayID = id
        let rawName = details["RelayName"] as? String ?? ""
        // connectcore uses the full ID when the signed label is empty.
        let name = rawName == id ? "" : RelayDescriptor.sanitizeDisplayName(rawName)
        relayName = name.isEmpty ? RelayDescriptor.sanitizeDisplayName(id.hasPrefix("relay_") ? String(id.dropFirst(6)) : id, maxCodePoints: 12) : name
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
