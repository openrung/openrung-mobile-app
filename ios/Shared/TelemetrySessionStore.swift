import Foundation

/// Persists the current telemetry `Session` to the App Group. PacketTunnel owns the session and
/// native VPN telemetry; the app reads its ID through `OpenRungVpn.getIdentity` so TypeScript can
/// associate speed-test telemetry without moving general VPN telemetry into JavaScript.
/// Port of the session half of Android `TelemetryManager`.
enum TelemetrySessionStore {
    private static let key = "telemetry_session"

    // One suite instance for the process lifetime: the computed-property form re-registered a
    // fresh UserDefaults with cfprefsd on every telemetry record.
    private static let defaults: UserDefaults? = UserDefaults(suiteName: AppConfig.appGroupIdentifier)

    static func current() -> TelemetrySession? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(TelemetrySession.self, from: data)
    }

    static func save(_ session: TelemetrySession?) {
        guard let session else {
            defaults?.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(session) {
            defaults?.set(data, forKey: key)
        }
    }
}
