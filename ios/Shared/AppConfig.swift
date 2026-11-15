import Foundation

enum AppConfig {
    static let vpnProfileName = "OpenRung VPN"
    // Recognized only to adopt an existing pre-rename profile without creating a duplicate.
    static let legacyVPNProfileName = "OpenRung Volunteer VPN"
    static let appGroupIdentifier = "group.com.openrung.app"
    static let packetTunnelBundleIdentifier = "com.openrung.app.PacketTunnel"
    static let providerBrokerURLKey = "broker_url"
    static let providerTargetCountryKey = "target_country"
    static let providerTargetRelayIDKey = "target_relay_id"
    /// App-group defaults key holding the raw split-tunnel config JSON (contract §3): written by
    /// the app's `setSplitTunnelConfig`, read by the extension via `SplitTunnelConfig.load`.
    static let splitTunnelConfigDefaultsKey = "split_tunnel_config"

    /// Primary relay-discovery URL passed to brokerapi. The native Go client owns built-in
    /// candidates, override policy, racing, relay verification, and transport selection; Swift
    /// receives only the winning URL and a verified relay-list snapshot.
    static let defaultBrokerURL = URL(string: "https://broker.openrung.org/")!

    /// SHA-256 pins for self-signed punch-coordinator leaf certificates, keyed by the exact host in
    /// the signed relay descriptor. A bare-IP coordinator is accepted only when it appears here;
    /// hostname coordinators not listed here use Go's normal public-CA and hostname validation.
    /// The pin authenticates the response that supplies UDP targets, the punch token, and the
    /// ephemeral QUIC certificate fingerprint.
    ///
    /// Rotation: ship a second certificate/endpoint and app pin before switching descriptors. This
    /// certificate is valid through 2036-06-29 and covers both current RelayHub IPv4 addresses.
    static let punchCoordinatorCertificateSHA256ByHost: [String: String] = [
        "43.201.124.63": "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5",
        "43.201.172.102": "70c3a26b9ac7315d1975f417eb9eabbecc98ec0e2d5baadb6c224e87fd99c8b5",
    ]

    static let loggingSubsystem = "com.openrung.app.PacketTunnel"
    static let engineDirectoryName = "OpenRungPacketTunnel"
    static let maxRecents = 8

    // App ↔ extension shared-state plumbing.
    static let darwinNotificationName = "com.openrung.app.state-changed"
}
