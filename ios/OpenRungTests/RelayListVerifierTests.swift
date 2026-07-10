import CryptoKit
import Foundation
import XCTest

// Shared signing test vector (SPEC v1 §2.3): the seed is 32 bytes of 0x42 — TEST ONLY, never a
// production key. These literals are copied verbatim from testdata/signing_vectors.json (`spec_vector`),
// mirroring how the Kotlin suite (RelayListVerifierTest.kt) embeds the vector as constants so all
// four clients are pinned to identical bytes. RelayListVerifier and its RelaySigningKey/
// RelayListVerificationError types are compiled directly into this test target (see the
// OpenRungTests target in project.yml / project.pbxproj), so no import of the app or extension is
// needed — the FailureClassifierTests isolation pattern.
private let VECTOR_PUBKEY_HEX = "2152f8d19b791d24453242e15f2eab6cb7cffa7b6a5ed30097960e069881db12"
private let VECTOR_KEY_ID = "3097e2dee2cb4a34"
private let VECTOR_BODY =
    "{\"count\":1,\"server_time\":\"2026-07-10T00:00:00Z\",\"not_after\":\"2026-07-10T00:30:00Z\"," +
    "\"key_id\":\"3097e2dee2cb4a34\",\"channel\":\"api\",\"limit\":1,\"relays\":[]}"
private let VECTOR_SIG_B64 =
    "K5UmJWzoEZ1YHOqZFf5E+ocNOITSe3WPvOo0GuyCRoiAxUk4eo/jcfqiuaPhrNeYrK3i8QcYI3LIv+zbVYq9Bw=="
private let VECTOR_HEADER = "ed25519;\(VECTOR_KEY_ID);\(VECTOR_SIG_B64)"

/// The vector's `not_after` is 2026-07-10T00:30:00Z; "now" sits 10 min after `server_time`, well
/// inside the signed freshness window.
private let VECTOR_NOW = isoDate("2026-07-10T00:10:00Z")

/// The SPEC v1 §5.2 verification algorithm against the shared §2.3 vector: the positive case, the
/// §12 negatives (each must reject as "candidate failed", i.e. throw `RelayListVerificationError`
/// whose message begins with the mandated "unsigned/invalid relay list"), the §4.2 advisory key_id
/// routing, and the §11 pinned-key CI guard over the production constants in
/// `AppConfig.relaySigningKeys`. Pure logic — no sockets, no app host.
final class RelayListVerifierTests: XCTestCase {

    /// Verifier pinned with ONLY the §2.3 test key, for the positive/negative body-and-header cases.
    private let testKeyVerifier = RelayListVerifier(
        keys: [RelaySigningKey(keyID: VECTOR_KEY_ID, publicKeyHex: VECTOR_PUBKEY_HEX)]
    )

    // MARK: - Positive

    func testSharedVectorVerifies() throws {
        let verified = try testKeyVerifier.verify(
            body: Data(VECTOR_BODY.utf8),
            signatureHeader: VECTOR_HEADER,
            channel: .api,
            requestedLimit: 1,
            now: VECTOR_NOW
        )
        XCTAssertEqual(verified.keyID, VECTOR_KEY_ID)
        // key_id derivation (§2.2): first 8 SHA-256 bytes of the raw pubkey, lowercase hex.
        XCTAssertEqual(deriveKeyID(try XCTUnwrap(hexToData(VECTOR_PUBKEY_HEX))), VECTOR_KEY_ID)
    }

    func testAcceptsInsideFiveMinuteSkewAllowance() throws {
        // not_after 00:30:00Z, skew 5 min → acceptance boundary is now = 00:35:00Z exactly.
        _ = try testKeyVerifier.verify(
            body: Data(VECTOR_BODY.utf8),
            signatureHeader: VECTOR_HEADER,
            channel: .api,
            requestedLimit: 1,
            now: isoDate("2026-07-10T00:34:59Z")
        )
    }

    // MARK: - §4.2 advisory key_id routing

    func testWrongAdvisoryKeyIdStillVerifiesUnderPinnedKey() throws {
        // The header routes to a key_id no pinned key has; the verifier must fall back to trying
        // every pinned key rather than reject, and report the PINNED key that actually verified.
        let header = "ed25519;ffffffffffffffff;\(VECTOR_SIG_B64)"
        let verified = try testKeyVerifier.verify(
            body: Data(VECTOR_BODY.utf8),
            signatureHeader: header,
            channel: .api,
            requestedLimit: 1,
            now: VECTOR_NOW
        )
        XCTAssertEqual(verified.keyID, VECTOR_KEY_ID)
    }

    // MARK: - Negatives (each rejects as a failed candidate)

    func testFlippedBodyByteIsRejected() {
        var body = Array(VECTOR_BODY.utf8)
        body[10] ^= 0x01
        let error = assertRejected(testKeyVerifier, body: Data(body))
        XCTAssertEqual(error, .signatureMismatch)
    }

    func testFlippedSignatureByteIsRejected() {
        // First base64 char K -> L still decodes to 64 bytes but is no longer the vector signature.
        let flipped = "L" + VECTOR_SIG_B64.dropFirst()
        XCTAssertNotEqual(flipped, VECTOR_SIG_B64)
        let error = assertRejected(testKeyVerifier, header: "ed25519;\(VECTOR_KEY_ID);\(flipped)")
        XCTAssertEqual(error, .signatureMismatch)
    }

    func testValidSignatureUnderUnpinnedKeyIsRejected() {
        // The production pin does not contain the §2.3 TEST key, so the (valid) vector signature
        // must not verify — the verifier falls through every pinned key first (§4.2).
        let productionPinned = RelayListVerifier(keys: AppConfig.relaySigningKeys)
        let error = assertRejected(productionPinned)
        XCTAssertEqual(error, .signatureMismatch)
    }

    func testMissingHeaderIsRejected() {
        let error = assertRejected(testKeyVerifier, header: nil)
        XCTAssertEqual(error, .missingSignatureHeader)
    }

    func testMalformedHeadersAreRejected() {
        let shortSignature = Data(count: 63).base64EncodedString()
        let malformed: [String] = [
            "",                                             // empty (present but unparseable)
            "ed25519;\(VECTOR_KEY_ID)",                     // two fields
            "\(VECTOR_HEADER);extra",                       // four fields
            "rsa;\(VECTOR_KEY_ID);\(VECTOR_SIG_B64)",       // wrong algorithm string
            "ED25519;\(VECTOR_KEY_ID);\(VECTOR_SIG_B64)",   // the algorithm literal is exact (§2.1)
            "ed25519;\(VECTOR_KEY_ID);%%%not-base64%%%",    // undecodable signature
            "ed25519;\(VECTOR_KEY_ID);\(shortSignature)",   // 63-byte signature (must be exactly 64)
        ]
        for header in malformed {
            let error = assertRejected(testKeyVerifier, header: header)
            XCTAssertEqual(error, .malformedSignatureHeader, "header should be malformed: \(header)")
        }
    }

    func testChannelMismatchIsRejected() {
        // The §2.3 body is signed for the API channel; verifying it on the mirror channel must fail
        // even though the signature is valid — a validly signed artifact cannot cross channels (§2.2).
        let error = assertRejected(testKeyVerifier, channel: .mirror, requestedLimit: nil)
        guard case .channelMismatch(let expected, let received)? = error else {
            return XCTFail("expected channelMismatch, got \(String(describing: error))")
        }
        XCTAssertEqual(expected, "mirror")
        XCTAssertEqual(received, "api")
    }

    func testLimitEchoMismatchIsRejected() {
        // The vector body echoes limit=1; a client that requested 2 must not accept it (§2.2
        // anti variant-steering).
        let error = assertRejected(testKeyVerifier, requestedLimit: 2)
        guard case .limitMismatch(let requested, let received)? = error else {
            return XCTFail("expected limitMismatch, got \(String(describing: error))")
        }
        XCTAssertEqual(requested, 2)
        XCTAssertEqual(received, 1)
    }

    func testExpiredNotAfterIsRejected() {
        // not_after 00:30:00Z; now 01:00:00Z is well past the 5-min slow-clock allowance.
        let error = assertRejected(testKeyVerifier, now: isoDate("2026-07-10T01:00:00Z"))
        guard case .expired? = error else {
            return XCTFail("expected expired, got \(String(describing: error))")
        }
    }

    // MARK: - §11 pinned-key CI guard

    func testPinnedProductionKeysMatchCommittedRotationVectors() throws {
        // A truncated or typo'd pinned constant must fail HERE, not on key-promotion day. Each
        // production key in AppConfig.relaySigningKeys must derive its committed key_id AND verify
        // its committed rotation vector — the vectors are index-aligned with the ordered pin (active
        // first, then standby). Copied verbatim from testdata/signing_vectors.json (`pinned_keys`).
        let rotationVectors: [(message: String, keyID: String, signatureB64: String)] = [
            (
                "openrung-signing-key-vector:active",
                "627405615601c589",
                "mELBVRsBe2+aeKYMniZ2F0HEV7n+8VcokBgailoLQW7JAleX6q8RQypVOO0y0p0+g/u89Uu+aaYpVfvpIAMRBQ=="
            ),
            (
                "openrung-signing-key-vector:standby",
                "672f79aa99a573cd",
                "KyYhv/R46Wmi1M4y+KPT4CUz40mVXzwG3hYG5U22v7qpxri0pj4wYCgxqjrGmh2hlFNcx8gZpIBFO1PhD7xABw=="
            ),
        ]

        XCTAssertEqual(
            AppConfig.relaySigningKeys.count,
            rotationVectors.count,
            "pinned-key count drifted from the committed rotation vectors"
        )

        for (index, vector) in rotationVectors.enumerated() {
            let pinned = AppConfig.relaySigningKeys[index]
            XCTAssertEqual(pinned.keyID, vector.keyID, "pinned key order or key_id drifted at index \(index)")

            let rawKey = try XCTUnwrap(
                hexToData(pinned.publicKeyHex),
                "pinned publicKeyHex is not valid hex: \(pinned.publicKeyHex)"
            )
            XCTAssertEqual(rawKey.count, 32, "pinned key is not a raw 32-byte Ed25519 key")
            XCTAssertEqual(
                deriveKeyID(rawKey),
                vector.keyID,
                "key_id derivation mismatch — corrupted pinned key at index \(index)"
            )

            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: rawKey)
            let signature = try XCTUnwrap(Data(base64Encoded: vector.signatureB64))
            XCTAssertTrue(
                publicKey.isValidSignature(signature, for: Data(vector.message.utf8)),
                "rotation vector failed to verify under pinned key \(vector.keyID) — corrupted pinned constant"
            )
        }
    }

    // MARK: - Helpers

    /// Asserts `verify` rejects and, per §5.2, that the surfaced message begins with the mandated
    /// "unsigned/invalid relay list" (never a generic network-error phrasing). Returns the thrown
    /// error so callers can additionally assert the specific case.
    @discardableResult
    private func assertRejected(
        _ verifier: RelayListVerifier,
        body: Data = Data(VECTOR_BODY.utf8),
        header: String? = VECTOR_HEADER,
        channel: RelayListVerifier.Channel = .api,
        requestedLimit: Int? = 1,
        now: Date = VECTOR_NOW,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> RelayListVerificationError? {
        do {
            _ = try verifier.verify(
                body: body,
                signatureHeader: header,
                channel: channel,
                requestedLimit: requestedLimit,
                now: now
            )
            XCTFail("verification unexpectedly succeeded", file: file, line: line)
            return nil
        } catch let error as RelayListVerificationError {
            XCTAssertTrue(
                (error.errorDescription ?? "").hasPrefix("unsigned/invalid relay list"),
                "message must begin with the mandated substring: \(String(describing: error.errorDescription))",
                file: file,
                line: line
            )
            return error
        } catch {
            XCTFail("unexpected error type: \(error)", file: file, line: line)
            return nil
        }
    }
}

// MARK: - File-local codecs (RelayListVerifier's own hex decoder is private)

/// Strict lowercase/uppercase hex → bytes; nil on odd length or any non-hex character.
private func hexToData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

/// key_id derivation (§2.2): lowercase hex of the first 8 bytes of SHA-256 over the raw public key.
private func deriveKeyID(_ publicKey: Data) -> String {
    SHA256.hash(data: publicKey).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// RFC3339 UTC parse for the fixed test clocks.
private func isoDate(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: value) else {
        fatalError("bad ISO8601 test date: \(value)")
    }
    return date
}
