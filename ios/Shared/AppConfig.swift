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

    /// Discovery broker (relay-list bootstrap) default, and — since discovery is HTTPS-only — the sole
    /// built-in discovery candidate. Discovery is the censorship-critical path: it runs BEFORE the VPN
    /// tunnel is up, and the relay list it returns defines which server the client trusts as its exit.
    /// The relay list is Ed25519-signed by the broker and verified against `relaySigningKeys` before
    /// it is decoded (see `RelayListVerifier`), so its authenticity no longer rests on the transport;
    /// the Cloudflare-fronted HTTPS endpoint stays the default because TLS + CDN edge IPs are hard to
    /// block and keep the client identity headers off the wire in cleartext.
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
    /// candidate to return relays wins (see `BrokerClient.firstReachable`). Every non-loopback
    /// candidate's relay list must carry a valid Ed25519 signature under `relaySigningKeys`
    /// (`RelayListVerifier`), so a censor or on-path attacker controlling a candidate can only fail
    /// it, never feed a forged relay set. Entries stay HTTPS regardless — TLS keeps the client
    /// identity headers confidential, which the signature does not.
    ///
    /// Two independent fronts are deployed — the Cloudflare Worker and an AWS CloudFront distribution
    /// (different provider AND DNS zone) — so a single CDN/zone/account failure no longer fails
    /// discovery CLOSED. Both proxy the one signing broker, so both serve verifiable lists. With
    /// signing in place, non-TLS / out-of-band channels (direct-IP fallback, signed mirrors, cached
    /// lists) become possible in later phases. Keep this in sync with the other clients' AppConfig.
    static let defaultBrokerURLs: [URL] = [
        defaultBrokerURL,
        // Independent second front: AWS CloudFront (different provider + DNS zone).
        URL(string: "https://d2r7mdpyevvs1m.cloudfront.net/")!,
    ]

    /// Ed25519 public keys trusted to sign the relay list, in pinned order — active key first, then
    /// the offline standby (a third "previous" slot appears during rotations; signing spec §4.2/§11).
    /// `keyID` is the lowercase hex of the first 8 bytes of SHA-256 over the raw 32-byte public key;
    /// it routes verification to the matching key first but is advisory only — on a miss every pinned
    /// key is tried. These constants MUST stay byte-identical to `testdata/signing_vectors.json`
    /// (`pinned_keys`), which is what the committed-vector CI guard compares them against, and in
    /// sync with the other clients' pinned lists. Rotating keys means shipping a release with the
    /// updated list — see the signing spec's promotion runbook.
    static let relaySigningKeys: [RelaySigningKey] = [
        RelaySigningKey(
            keyID: "627405615601c589",
            publicKeyHex: "176c03cbc70833285abcea75f2a0e137bd687629142408c22806a86308bd4974"
        ),
        RelaySigningKey(
            keyID: "672f79aa99a573cd",
            publicKeyHex: "5b2698cfa7a796c671a30aabd5475d55095b91464221f051837eb8fe01f36ea2"
        ),
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
