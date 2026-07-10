import CryptoKit
import Foundation

/// One Ed25519 public key the client trusts to sign the relay list (signing spec §4.2). Pinned as
/// raw-key lowercase hex (not SPKI/PEM) so the committed CI vectors (`testdata/signing_vectors.json`)
/// can be compared byte-for-byte against these constants across all four clients.
public struct RelaySigningKey: Equatable, Sendable {
    /// Lowercase hex of the first 8 bytes of SHA-256 over the raw 32-byte public key (spec §2.2).
    /// Advisory routing only — it picks which pinned key to try first, never a trust decision.
    public let keyID: String
    /// The raw 32-byte Ed25519 public key, lowercase hex.
    public let publicKeyHex: String

    public init(keyID: String, publicKeyHex: String) {
        self.keyID = keyID
        self.publicKeyHex = publicKeyHex
    }
}

/// Why a relay-list response failed authentication. Every case means "candidate failed — fall
/// through to the next broker candidate", exactly like a network error; none is retryable against
/// the same response. Carries enough context for diagnostics, and the user-facing description
/// deliberately says "unsigned/invalid relay list" (spec §5.2) rather than reading like a
/// generic network failure.
public enum RelayListVerificationError: Error, Equatable {
    /// 2xx response with no `X-OpenRung-Relays-Signature` header — a pre-signing broker, a
    /// stripped header, or an injected body. All indistinguishable, all rejected.
    case missingSignatureHeader
    /// Header present but not `ed25519;<key_id>;<64-byte base64 signature>` (spec §2.1).
    case malformedSignatureHeader
    /// The signature does not verify over the raw body bytes under ANY pinned key (§4.2 requires
    /// trying every key after the advisory key_id route misses).
    case signatureMismatch
    /// Signature verified, but the body is not JSON carrying the signed freshness/binding fields
    /// (`not_after`, `channel`, and `limit` on the API channel) in the expected shapes.
    case malformedSignedFields
    /// Signed `channel` differs from the channel this candidate was fetched on — a mirror
    /// artifact replayed into an API slot, or vice versa (spec §2.2).
    case channelMismatch(expected: String, received: String?)
    /// Signed `limit` echo differs from the limit this client requested — a validly signed
    /// variant of the list steered at us from a different query (spec §2.2).
    case limitMismatch(requested: Int?, received: Int?)
    /// Signed and well-formed, but `not_after` is more than the skew allowance in the past:
    /// a replay of an expired list (or a fast device clock; degraded-UI handling is spec §5.2).
    case expired(notAfter: Date)
}

extension RelayListVerificationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingSignatureHeader:
            return "unsigned/invalid relay list: response carries no signature"
        case .malformedSignatureHeader:
            return "unsigned/invalid relay list: malformed signature header"
        case .signatureMismatch:
            return "unsigned/invalid relay list: signature does not match any pinned key"
        case .malformedSignedFields:
            return "unsigned/invalid relay list: signed freshness fields missing or malformed"
        case .channelMismatch(let expected, let received):
            return "unsigned/invalid relay list: signed for channel \(received ?? "<none>"), expected \(expected)"
        case .limitMismatch(let requested, let received):
            return "unsigned/invalid relay list: signed limit \(received.map(String.init) ?? "<none>") does not echo requested \(requested.map(String.init) ?? "<none>")"
        case .expired(let notAfter):
            return "unsigned/invalid relay list: expired (not_after \(notAfter))"
        }
    }
}

/// Verifies broker relay-list responses per the signing spec §5.2: Ed25519 over the EXACT raw
/// body bytes as received (never re-serialized JSON), against an ordered list of pinned operator
/// keys, then freshness/binding checks on fields inside the signed bytes. Detaching authenticity
/// from the transport is what makes non-TLS discovery channels (direct-IP fallback, mirrors,
/// cached lists) safe to add later.
///
/// Scope (mirrors the spec's threat model): this authenticates the CHANNEL only. A compromised
/// broker signs whatever it likes; a censor can still block or strip — both degrade to "candidate
/// failed, fall through", never to accepting forged data.
///
/// Foundation + CryptoKit only (both system frameworks, no new dependencies), and deliberately
/// free of any other Shared-layer type so a logic-test target can compile this file in isolation
/// (the FailureClassifier test pattern in project.yml).
public struct RelayListVerifier: Sendable {
    /// The signed channel a candidate belongs to (spec §2.2): broker API fronts/direct IP vs.
    /// published mirror artifacts. Checked against the in-body `channel` so a validly signed
    /// artifact can never be cross-fed between channels with different freshness regimes.
    public enum Channel: String, Sendable {
        case api
        case mirror
    }

    /// Successful verification result. `keyID` is the pinned key that actually verified (which
    /// may differ from the advisory key_id in the header) — reported in telemetry as the
    /// compromise-detection signal (spec §5.2 step 5 / §8).
    public struct Verified: Equatable, Sendable {
        public let keyID: String
    }

    /// Response header carrying `ed25519;<key_id>;<base64 signature>` (spec §2.1). Match it
    /// case-insensitively: HTTP/2+ lowercases header names on the wire.
    public static let signatureHeaderName = "X-OpenRung-Relays-Signature"

    /// How far in the past a signed `not_after` may lie and still be accepted — absorbs slow
    /// device clocks (spec §5.2/§14 resolved this at 5 minutes; it widens the ~30 min API replay
    /// window to ~35 min, accepted).
    public static let clockSkewAllowance: TimeInterval = 5 * 60

    private struct ParsedKey {
        let keyID: String
        let publicKey: Data
    }

    private let keys: [ParsedKey]

    /// `keys` in pinned order (active first). Entries whose hex is not exactly 32 raw bytes are
    /// dropped rather than half-trusted — the committed-vector CI guard (spec §11) is what turns
    /// a typo'd constant into a test failure instead of a promotion-day outage.
    public init(keys: [RelaySigningKey]) {
        self.keys = keys.compactMap { key in
            guard let raw = Data(hexEncoded: key.publicKeyHex), raw.count == 32 else { return nil }
            return ParsedKey(keyID: key.keyID.lowercased(), publicKey: raw)
        }
    }

    /// Runs the spec §5.2 checks over `body` — the raw response bytes exactly as read off the
    /// connection, which MUST also be the buffer the caller later decodes. Throws
    /// `RelayListVerificationError` (candidate failed) or returns the pinned key that verified.
    ///
    /// `requestedLimit` is the limit this client put in the query (the API channel's signed body
    /// echoes it back); pass `nil` on the mirror channel, where the check is skipped.
    public func verify(
        body: Data,
        signatureHeader: String?,
        channel: Channel,
        requestedLimit: Int?,
        now: Date = Date()
    ) throws -> Verified {
        // (§5.2 step 2) Require and parse the signature header.
        guard let signatureHeader else {
            throw RelayListVerificationError.missingSignatureHeader
        }
        guard let (headerKeyID, signature) = Self.parseSignatureHeader(signatureHeader) else {
            throw RelayListVerificationError.malformedSignatureHeader
        }

        // (§5.2 step 3) Verify over the raw bytes. The header's key_id routes to the matching
        // pinned key first but is advisory only (§4.2): on miss or failure every pinned key is
        // tried, so a broker key_id bug costs one extra ~50 µs verify, not an outage.
        var candidates = keys.filter { $0.keyID == headerKeyID }
        candidates.append(contentsOf: keys.filter { $0.keyID != headerKeyID })
        let verifiedKey = candidates.first { candidate in
            guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: candidate.publicKey) else {
                return false
            }
            return publicKey.isValidSignature(signature, for: body)
        }
        guard let verifiedKey else {
            throw RelayListVerificationError.signatureMismatch
        }

        // (§5.2 step 4) Parse the SAME buffer and check the fields that live inside the signed
        // bytes — they are what an attacker replaying a stale-but-validly-signed body cannot
        // rewrite. Unknown extra keys stay ignored for forward compatibility.
        guard let envelope = try? JSONDecoder().decode(SignedEnvelope.self, from: body) else {
            throw RelayListVerificationError.malformedSignedFields
        }
        guard envelope.channel == channel.rawValue else {
            throw RelayListVerificationError.channelMismatch(expected: channel.rawValue, received: envelope.channel)
        }
        if channel == .api {
            // Echoed-limit binding: a signed `limit=1` body must never satisfy a `limit=20`
            // request (anti variant-steering, §2.2). Mirror bodies carry no limit; skipped there.
            guard let echoed = envelope.limit, echoed == requestedLimit else {
                throw RelayListVerificationError.limitMismatch(requested: requestedLimit, received: envelope.limit)
            }
        }
        guard let notAfterString = envelope.notAfter, let notAfter = Self.parseRFC3339(notAfterString) else {
            throw RelayListVerificationError.malformedSignedFields
        }
        guard notAfter >= now - Self.clockSkewAllowance else {
            throw RelayListVerificationError.expired(notAfter: notAfter)
        }

        return Verified(keyID: verifiedKey.keyID)
    }

    /// Whether `host` is a loopback destination, for the dev-flow exemption: verification is
    /// required for ALL candidates except loopback, mirroring the desktop client's
    /// `EnforceSecureBrokerURL` loopback-http allowance (internal/client/broker.go) and the other
    /// mobile clients. "localhost", any 127.0.0.0/8 dotted-quad, and the IPv6 loopback (with or
    /// without URL brackets) qualify; everything else — including user overrides — must verify.
    public static func isLoopbackHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased(), host.isEmpty == false else { return false }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host == "localhost" || host == "::1" || host == "0:0:0:0:0:0:0:1" {
            return true
        }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.allSatisfy { UInt8($0) != nil }
            && UInt8(octets[0]) == 127
    }

    // MARK: - Internals

    /// The signed freshness/binding fields (spec §2.2), decoded from the same buffer the
    /// signature covered. `server_time`/`relays` etc. are left to `RelayListResponse`; this
    /// struct exists so verification never depends on the full model layer.
    private struct SignedEnvelope: Decodable {
        let notAfter: String?
        let channel: String?
        let limit: Int?

        enum CodingKeys: String, CodingKey {
            case notAfter = "not_after"
            case channel
            case limit
        }
    }

    /// Parses `ed25519;<key_id>;<base64 signature>` (spec §2.1): exactly three `;`-separated
    /// fields, the literal algorithm string, and a standard-base64 (padded) 64-byte signature.
    private static func parseSignatureHeader(_ header: String) -> (keyID: String, signature: Data)? {
        let fields = header
            .trimmingCharacters(in: .whitespaces)
            .split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0] == "ed25519" else {
            return nil
        }
        guard let signature = Data(base64Encoded: String(fields[2])), signature.count == 64 else {
            return nil
        }
        return (String(fields[1]).lowercased(), signature)
    }

    private static let rfc3339 = ISO8601DateFormatter()

    private static let rfc3339Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// RFC3339 UTC parse for `not_after`. The broker emits whole-second timestamps; the
    /// fractional-second fallback is client-side tolerance only (ISO8601DateFormatter accepts
    /// exactly one of the two shapes per configuration, and both formatters are thread-safe).
    private static func parseRFC3339(_ value: String) -> Date? {
        rfc3339.date(from: value) ?? rfc3339Fractional.date(from: value)
    }
}

private extension Data {
    /// Strict lowercase/uppercase hex → bytes; nil on odd length or any non-hex character.
    init?(hexEncoded hex: String) {
        let digits = Array(hex)
        guard digits.count % 2 == 0 else { return nil }
        var bytes = Data(capacity: digits.count / 2)
        var index = 0
        while index < digits.count {
            guard let high = digits[index].hexDigitValue, let low = digits[index + 1].hexDigitValue else {
                return nil
            }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = bytes
    }
}
