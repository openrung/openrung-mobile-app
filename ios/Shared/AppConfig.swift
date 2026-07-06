import Foundation

enum AppConfig {
    static let vpnProfileName = "OpenRung Volunteer VPN"
    static let appGroupIdentifier = "group.com.openrung.mobile"
    static let packetTunnelBundleIdentifier = "com.openrung.mobile.PacketTunnel"
    static let providerBrokerURLKey = "broker_url"
    static let providerTargetCountryKey = "target_country"
    static let providerTargetRelayIDKey = "target_relay_id"

    /// Discovery broker (relay-list bootstrap) default, and — since discovery is HTTPS-only — the sole
    /// built-in discovery candidate. Discovery is the censorship-critical path: it runs BEFORE the VPN
    /// tunnel is up, and the relay list it returns defines which server the client trusts as its exit.
    /// The relay list is NOT signed, so it must only be fetched over a TLS-authenticated channel; the
    /// Cloudflare-fronted HTTPS endpoint (TLS + CDN edge IPs) is both hard to block and unforgeable.
    static let defaultBrokerURL = URL(string: "https://broker.openrung.org/")!

    /// Telemetry / heartbeat / speed-test target. Uses the same Cloudflare-fronted HTTPS broker as
    /// discovery, so this traffic is TLS-protected — the app never sends anything in cleartext. Kept
    /// as a separate constant from `defaultBrokerURL` because telemetry is high-volume (heartbeats
    /// fire ~once/minute per connected user), so it consumes the Cloudflare Worker free-tier request
    /// quota (100k/day). If that quota becomes a constraint, the planned fix is to send telemetry
    /// direct-to-origin over TLS via a dedicated unproxied hostname — "Option A" in
    /// docs/ARCHITECTURE.md § "Network transport". Never revert to a raw-IP HTTP endpoint: that leaked
    /// the user's real pre-VPN IP, geo and stable client ID in cleartext.
    static let telemetryBrokerURL = URL(string: "https://broker.openrung.org/")!

    /// Ordered discovery candidates, tried in order until one returns relays (see
    /// `BrokerClient.firstReachable`). HTTPS-only: the unsigned relay list must never be fetched over
    /// a forgeable cleartext channel, so there is deliberately NO raw-IP fallback here. A blocked edge
    /// fails discovery CLOSED (offline) rather than open to an attacker-injected relay.
    static let defaultBrokerURLs: [URL] = [defaultBrokerURL]

    /// Ordered broker candidates for a connection attempt: the caller-selected `primary` (the provider
    /// configuration's broker, today the default) first, then the built-in `defaultBrokerURLs`,
    /// de-duplicated while preserving order.
    static func brokerCandidates(primary: URL?) -> [URL] {
        BrokerClient.candidates(primary: primary, fallbacks: defaultBrokerURLs)
    }
    static let loggingSubsystem = "com.openrung.mobile.PacketTunnel"
    static let engineDirectoryName = "OpenRungPacketTunnel"
    static let relayLimit = 5
    static let directoryRelayLimit = 20
    static let maxRecents = 8

    // App ↔ extension shared-state plumbing.
    static let darwinNotificationName = "com.openrung.mobile.state-changed"
    static let telemetryOutboxFilename = "outbox.json"

    // Heartbeat cadence (random in this range), matching Android.
    static let heartbeatMinDelayMs: UInt64 = 50_000
    static let heartbeatMaxDelayMs: UInt64 = 70_000
}
