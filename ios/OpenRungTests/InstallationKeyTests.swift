import CryptoKit
import Foundation
import Security
import XCTest

/// The Swift half of testdata/installation-key-vectors.json: the Go suite proves the raw
/// signatures and SPKI there verify with brokerapi exactly as the broker checks them; this suite
/// proves the SecKey-format conversions land on those bytes. The round trip uses a non-permanent
/// software key, because hostless logic tests have no keychain access.
final class InstallationKeyTests: XCTestCase {
    private var vectors: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // OpenRungTests
            .deletingLastPathComponent()  // ios
            .deletingLastPathComponent()  // repository root
            .appendingPathComponent("testdata/installation-key-vectors.json")
        vectors = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func hex(_ value: Any?) throws -> Data {
        let text = try XCTUnwrap(value as? String)
        var bytes = [UInt8]()
        var index = text.startIndex
        while index < text.endIndex {
            let end = text.index(index, offsetBy: 2)
            bytes.append(try XCTUnwrap(UInt8(text[index..<end], radix: 16)))
            index = end
        }
        return Data(bytes)
    }

    func testDERSignaturesConvertToTheVectorsRawRAndS() throws {
        let cases = try XCTUnwrap(vectors["signatures"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for item in cases {
            let raw = try EcdsaP256.rawSignature(der: try hex(item["der_signature_hex"]))
            XCTAssertEqual(raw, try hex(item["raw_signature_hex"]), item["name"] as? String ?? "")
        }
    }

    func testMalformedDERSignaturesAreRejected() throws {
        let cases = try XCTUnwrap(vectors["invalid_der"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 4)
        for item in cases {
            XCTAssertThrowsError(try EcdsaP256.rawSignature(der: try hex(item["der_hex"])), item["name"] as? String ?? "")
        }
    }

    func testX963PointWrapsAsTheP256SubjectPublicKeyInfo() throws {
        let spki = try EcdsaP256.subjectPublicKeyInfo(x963Point: try hex(vectors["x963_point_hex"]))
        XCTAssertEqual(spki, try hex(vectors["spki_der_hex"]))
        XCTAssertThrowsError(try EcdsaP256.subjectPublicKeyInfo(x963Point: Data(repeating: 4, count: 33)))
    }

    func testNativeSignaturesVerifyAsRawRAndSOverTheGivenDigest() throws {
        let key = InstallationKey(source: Self.softwareKey)
        let digest = SHA256.hash(data: Data("openrung-user-auth-v1".utf8))
        let raw = try key.sign(Data(digest))
        XCTAssertEqual(raw.count, 64)
        let publicKey = try P256.Signing.PublicKey(derRepresentation: try key.publicKey())
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        // Passing the digest itself proves SecKey did not hash it again.
        XCTAssertTrue(publicKey.isValidSignature(signature, for: digest))
        XCTAssertThrowsError(try key.sign(Data(count: 31)))
    }

    func testKeyLoadsOnceAndAFailedLoadIsRetried() throws {
        var calls = 0
        let software = try Self.softwareKey()
        let key = InstallationKey(source: {
            calls += 1
            if calls == 1 { throw InstallationKeyError("keychain locked") }
            return software
        })
        XCTAssertThrowsError(try key.publicKey())
        let first = try key.publicKey()
        _ = try key.sign(Data(count: 32))
        XCTAssertEqual(try key.publicKey(), first)
        XCTAssertEqual(calls, 2)
    }

    private static func softwareKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw InstallationKeyError("create", error)
        }
        return key
    }
}
