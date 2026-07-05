import Foundation

/// One live traffic sample (contract §3 `TrafficStats`): instantaneous rates in bytes/second
/// plus per-session cumulative totals.
struct TrafficSnapshot: Codable {
    var upBps: Int64
    var downBps: Int64
    var upTotalBytes: Int64
    var downTotalBytes: Int64
    var updatedAtMs: Int64
}

/// App-group-backed traffic feed: the PacketTunnel extension writes a sample every ~2s while
/// the tunnel is up (and clears it on stop); the app re-reads on a dedicated Darwin
/// notification and re-emits to JS. Kept apart from `SharedConnectionState` so the frequent
/// samples never re-serialize the full log + recents snapshot.
enum SharedTrafficState {
    private static let key = "traffic_state"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppConfig.appGroupIdentifier)
    }

    static func snapshot() -> TrafficSnapshot? {
        guard
            let data = defaults?.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(TrafficSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    // MARK: - Mutators (called by the extension)

    static func write(_ snapshot: TrafficSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
        postDarwinNotification()
    }

    /// Removes the sample and notifies once — the app side turns the missing key into the
    /// contract's final zeroed emission.
    static func clear() {
        guard let defaults, defaults.object(forKey: key) != nil else { return }
        defaults.removeObject(forKey: key)
        postDarwinNotification()
    }

    private static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppConfig.trafficDarwinNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
