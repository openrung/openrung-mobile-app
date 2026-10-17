import Foundation
import Security

/// The installation's ADR-006 identity key: one P-256 key in the Packet Tunnel extension's
/// keychain, in the Secure Enclave when the device has one, created on first use and never
/// exported. It stays across app upgrades; there is no recovery, so a new key means a new
/// enrollment. The broker derives the user ID from it; it is unrelated to the telemetry install
/// ID (`ClientIdentity`). Only the extension runs the engine, so the key lives in the extension's
/// default keychain access group and the app never reads it.
///
/// Methods run on Go workers, possibly concurrently. Failures are thrown and reach connectcore as
/// errors, which logs the reason and keeps the session on the public relay list.
final class InstallationKey {
    private let lock = NSLock()
    private let source: () throws -> SecKey
    private var cached: SecKey?

    init(source: @escaping () throws -> SecKey) {
        self.source = source
    }

    static func keychain() -> InstallationKey { InstallationKey(source: KeychainInstallationKey.loadOrCreate) }

    private func privateKey() throws -> SecKey {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let key = try source()
        cached = key
        return key
    }

    /// DER SubjectPublicKeyInfo of the P-256 public key.
    func publicKey() throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(try privateKey()) else {
            throw InstallationKeyError("installation key has no public key")
        }
        var error: Unmanaged<CFError>?
        guard let point = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw InstallationKeyError("export public key", error)
        }
        return try EcdsaP256.subjectPublicKeyInfo(x963Point: point)
    }

    /// Raw 64-byte r‖s signature over `digest`, which is already a SHA-256 digest.
    func sign(_ digest: Data) throws -> Data {
        guard digest.count == EcdsaP256.digestBytes else {
            throw InstallationKeyError("digest must be \(EcdsaP256.digestBytes) bytes")
        }
        var error: Unmanaged<CFError>?
        // The Digest algorithm signs the bytes as given; SecKey returns ASN.1 DER.
        guard let der = SecKeyCreateSignature(try privateKey(), .ecdsaSignatureDigestX962SHA256, digest as CFData, &error) as Data? else {
            throw InstallationKeyError("sign", error)
        }
        return try EcdsaP256.rawSignature(der: der)
    }
}

struct InstallationKeyError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }

    init(_ operation: String, _ error: Unmanaged<CFError>?) {
        let reason = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown error"
        errorDescription = "keychain \(operation): \(reason)"
    }

    init(_ operation: String, status: OSStatus) {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus"
        errorDescription = "keychain \(operation): \(reason) (\(status))"
    }
}

enum KeychainInstallationKey {
    // Versioned so a future key policy can live beside this one instead of replacing it.
    private static let tag = Data("com.openrung.installation-key.v1".utf8)

    static func loadOrCreate() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() {
            return item as! SecKey
        }
        // Only a missing key is created. Any other failure (for example, before the first unlock
        // after a reboot) throws, because a replacement key would make this installation a new user.
        guard status == errSecItemNotFound else { throw InstallationKeyError("load", status: status) }
        if let key = try? create(secureEnclave: true) { return key }
        return try create(secureEnclave: false)
    }

    private static func create(secureEnclave: Bool) throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag,
        ]
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
        ]
        if secureEnclave {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error) else {
                throw InstallationKeyError("access control", error)
            }
            privateAttributes[kSecAttrAccessControl as String] = access
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        } else {
            privateAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        attributes[kSecPrivateKeyAttrs as String] = privateAttributes
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw InstallationKeyError("create", error)
        }
        return key
    }
}

/// P-256 encodings between Security framework output and what the Go binding expects.
enum EcdsaP256 {
    static let digestBytes = 32
    private static let coordinateBytes = 32

    // SEQUENCE { SEQUENCE { id-ecPublicKey, prime256v1 }, BIT STRING (0 unused bits) }
    private static let spkiPrefix = Data([
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08,
        0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
    ])

    /// Wraps SecKey's X9.63 uncompressed point (0x04 ‖ X ‖ Y) in a P-256 SubjectPublicKeyInfo.
    static func subjectPublicKeyInfo(x963Point point: Data) throws -> Data {
        guard point.count == 1 + 2 * coordinateBytes, point.first == 0x04 else {
            throw InstallationKeyError("public key is not an uncompressed P-256 point")
        }
        return spkiPrefix + point
    }

    /// Converts an ASN.1 DER ECDSA signature (SEQUENCE of two positive INTEGERs) to the
    /// fixed-width r‖s form, left-padding each half to 32 bytes. Rejects anything that is not
    /// exactly one well-formed P-256 signature.
    static func rawSignature(der input: Data) throws -> Data {
        let der = [UInt8](input)
        var offset = 0
        let invalid = InstallationKeyError("malformed ECDSA signature")
        func next() throws -> Int {
            guard offset < der.count else { throw invalid }
            defer { offset += 1 }
            return Int(der[offset])
        }
        // A P-256 signature is at most 72 bytes, so every length is short-form.
        func length() throws -> Int {
            let value = try next()
            guard value < 0x80 else { throw invalid }
            return value
        }
        func integer() throws -> [UInt8] {
            guard try next() == 0x02 else { throw invalid }
            let size = try length()
            guard size > 0, offset + size <= der.count else { throw invalid }
            let value = der[offset..<(offset + size)]
            offset += size
            guard value.first! < 0x80 else { throw invalid } // negative
            let magnitude = value.drop(while: { $0 == 0 })
            guard !magnitude.isEmpty, magnitude.count <= coordinateBytes else { throw invalid }
            return [UInt8](repeating: 0, count: coordinateBytes - magnitude.count) + magnitude
        }
        guard try next() == 0x30 else { throw invalid }
        let sequence = try length()
        guard offset + sequence == der.count else { throw invalid }
        let raw = try integer() + integer()
        guard offset == der.count else { throw invalid }
        return Data(raw)
    }
}
