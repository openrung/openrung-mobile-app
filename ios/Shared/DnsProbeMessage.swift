import Foundation

/// Minimal RFC 1035 codec for the fresh-DNS probe. Only what the probe needs: encode one A/IN
/// question and recognize a well-formed response to it. Any RCODE counts — including NXDOMAIN —
/// because the response arriving at all is what proves the hijack → DoH → proxy path.
/// Mirrors Android `DnsProbeMessage`.
public enum DnsProbeMessage {
    public static func query(transactionID: UInt16, name: String) -> Data {
        var data = Data(capacity: headerLength + name.count + 6)
        data.appendUInt16(transactionID)
        data.appendUInt16(0x0100) // flags: standard query, recursion desired
        data.appendUInt16(1) // QDCOUNT
        data.appendUInt16(0) // ANCOUNT
        data.appendUInt16(0) // NSCOUNT
        data.appendUInt16(0) // ARCOUNT
        for label in name.split(separator: ".") {
            precondition(label.count >= 1 && label.count <= 63, "invalid probe QNAME label")
            data.append(UInt8(label.count))
            data.append(contentsOf: Array(label.utf8))
        }
        data.append(0) // root label
        data.appendUInt16(1) // QTYPE A
        data.appendUInt16(1) // QCLASS IN
        return data
    }

    /// True when `data` is a DNS response (QR set) matching `transactionID`. Any RCODE.
    public static func isResponse(_ data: Data, transactionID: UInt16) -> Bool {
        guard data.count >= headerLength else { return false }
        let bytes = [UInt8](data.prefix(3))
        let responseID = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        guard responseID == transactionID else { return false }
        return bytes[2] & 0x80 != 0
    }

    /// A fresh label per query defeats every cache in the chain (all are keyed by QNAME).
    public static func nonceLabel() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }

    private static let headerLength = 12
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(value & 0xFF))
    }
}
