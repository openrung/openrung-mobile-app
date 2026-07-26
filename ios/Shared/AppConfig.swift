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

    /// Telemetry / heartbeat / speed-test target. Uses the same Cloudflare-fronted HTTPS broker as
    /// discovery, so this traffic is TLS-protected — the app never sends anything in cleartext. Kept
    /// as a separate constant from `defaultBrokerURL` because telemetry is high-volume (heartbeats
    /// fire ~once/minute per connected user), so it consumes the Cloudflare Worker free-tier request
    /// quota (100k/day). If that quota becomes a constraint, the planned fix is to send telemetry
    /// direct-to-origin over TLS via a dedicated unproxied hostname — "Option A" in
    /// docs/ARCHITECTURE.md § "Network transport". Never revert to a raw-IP HTTP endpoint: that leaked
    /// the user's real pre-VPN IP, geo and stable client ID in cleartext.
    static let telemetryBrokerURL = URL(string: "https://broker.openrung.org/")!

    /// Broker fronts retained for WSS-ticket ordering and other paths that have their own explicit
    /// policy. Native relay discovery no longer constructs candidates here: brokerapi owns its
    /// default order, custom-override handling, racing, and relay-list verification.
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
