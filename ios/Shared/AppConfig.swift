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

    /// Ordered discovery candidates, raced with a staggered start: the first entry starts
    /// immediately, each later entry joins `discoveryStaggerMs` after the previous one, and the first
    /// candidate to return relays wins (see `BrokerClient.firstReachable`). Every entry MUST be
    /// HTTPS: the relay list is not yet signed, so it is authenticated only by the TLS cert of the
    /// serving host — a cleartext/bare-IP entry would let an on-path censor inject a malicious relay
    /// set.
    ///
    /// Only one front is deployed today, so a censor who blocks it fails discovery CLOSED (offline).
    /// Closing that single point of failure is the front-diversity layer: adding more *HTTPS* fronts
    /// on independent CDNs/domains is safe now (still TLS-authenticated) and just needs the extra
    /// fronts deployed. Non-TLS / out-of-band channels (raw IP, cached blobs) stay off this list until
    /// the broker signs the relay list. Keep this in sync with the other clients' AppConfig.
    static let defaultBrokerURLs: [URL] = [
        defaultBrokerURL,
        // Additional HTTPS fronts once deployed (second domain / second CDN), e.g.:
        //   URL(string: "https://broker2.openrung.org/")!,
    ]

    /// Ordered broker candidates for a connection attempt: the caller-selected `primary` (the provider
    /// configuration's broker, today the default) first, then the built-in `defaultBrokerURLs`,
    /// de-duplicated while preserving order. A GENUINE override (a primary that is not one of the
    /// defaults) is flagged `overrideFirst`: `BrokerClient.firstReachable` tries it strictly first
    /// with its full per-attempt timeout — a user's custom broker is never silently outrun by a
    /// default front merely for being slower than the stagger — and the defaults race as fallbacks
    /// only after it fails. A primary that echoes a default keeps the pure staggered race, where
    /// list position is just a head start of `discoveryStaggerMs` per position.
    static func brokerCandidates(primary: URL?) -> BrokerCandidates {
        BrokerClient.candidates(primary: primary, fallbacks: defaultBrokerURLs)
    }

    /// Stagger interval of the discovery race (`BrokerClient.firstReachable`): candidate N+1 is
    /// started this many milliseconds after candidate N unless an attempt has already succeeded.
    /// Small enough that a blocked/blackholed primary front only delays discovery by ~2.5 s per
    /// fallback position (instead of a full request timeout), large enough that a healthy primary
    /// almost always answers before the first fallback is ever contacted, keeping fallback-front load
    /// near zero. MUST stay in sync with desktop `DiscoveryStagger` (Go config package) and the
    /// RN/Kotlin AppConfigs — the staggered-race semantics are identical across all four clients.
    static let discoveryStaggerMs: UInt64 = 2_500

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
