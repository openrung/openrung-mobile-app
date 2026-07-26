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

    /// Native VPN telemetry / heartbeat target. Uses the same Cloudflare-fronted HTTPS broker as
    /// discovery, so this traffic is TLS-protected — the app never sends anything in cleartext.
    /// React Native speed-test telemetry has its own TypeScript constant and reaches this broker
    /// through `OpenRungBroker`, not this shared Swift client. Kept separate from `defaultBrokerURL`
    /// because telemetry is high-volume (heartbeats fire ~once/minute per connected user), so it
    /// consumes the Cloudflare Worker free-tier request quota (100k/day). If that quota becomes a
    /// constraint, the planned fix is to send telemetry direct-to-origin over TLS via a dedicated
    /// unproxied hostname — "Option A" in docs/ARCHITECTURE.md § "Network transport". Never revert
    /// to a raw-IP HTTP endpoint: that leaked the user's real pre-VPN IP, geo and stable client ID
    /// in cleartext.
    static let telemetryBrokerURL = URL(string: "https://broker.openrung.org/")!

    /// Broker fronts retained for WSS-ticket ordering and other paths that have their own explicit
    /// policy. Native relay discovery no longer constructs candidates here: brokerapi owns its
    /// default order, custom-override handling, racing, and relay-list verification.
    ///
    /// Two independent fronts are deployed — the Cloudflare Worker and an AWS CloudFront distribution
    /// (different provider AND DNS zone). Keep this order stable for WSS failover.
    static let defaultBrokerURLs: [URL] = [
        defaultBrokerURL,
        // Independent second front: AWS CloudFront (different provider + DNS zone).
        URL(string: "https://d2r7mdpyevvs1m.cloudfront.net/")!,
    ]

    static let loggingSubsystem = "com.openrung.app.PacketTunnel"
    static let engineDirectoryName = "OpenRungPacketTunnel"
    static let relayLimit = 5
    static let directoryRelayLimit = 20
    static let maxRecents = 8

    // App ↔ extension shared-state plumbing.
    static let darwinNotificationName = "com.openrung.app.state-changed"
    static let telemetryOutboxFilename = "outbox.json"

    // Heartbeat cadence (random in this range), matching Android.
    static let heartbeatMinDelayMs: UInt64 = 50_000
    static let heartbeatMaxDelayMs: UInt64 = 70_000
}
