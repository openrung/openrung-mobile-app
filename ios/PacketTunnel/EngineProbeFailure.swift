import Foundation
import Network

/// Native error facts survive the string-based gomobile callback. Go's existing
/// classifier owns reason tokens; the platform attests only a proved remote
/// stage and the typed facts that would otherwise be lost in NSError's text.
enum EngineProbeFailure {
    static func result(_ error: Error, cancelled: Bool, ownsTunnel: Bool) -> [String: Any] {
        var result: [String: Any] = ["error": error.localizedDescription, "failure_facts": facts(error)]
        if !cancelled, ownsTunnel, !(error is CancellationError), isGenuineRemoteDataPathFailure(error) {
            result["remote_stage"] = error is DnsPathUnverifiedError ? "dns_probe" : "internet_probe"
        }
        return result
    }

    private static func facts(_ error: Error, depth: Int = 0) -> [String: Any] {
        guard depth < 8 else { return [:] }
        if error is CancellationError { return ["cancelled": true] }
        if let dns = error as? DnsPathUnverifiedError { return facts(dns.underlying, depth: depth + 1) }
        if let probe = error as? InternetProbeError, let underlying = probe.underlyingError { return facts(underlying, depth: depth + 1) }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled: return ["cancelled": true]
            case .timedOut: return ["timeout": true]
            case .cannotFindHost, .dnsLookupFailed: return ["dns": true]
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired: return ["tls": true]
            case .cannotConnectToHost: return ["errno": Int(ECONNREFUSED)]
            case .notConnectedToInternet, .networkConnectionLost: return ["errno": Int(ENETUNREACH)]
            default: break
            }
        }
        if let network = error as? NWError {
            switch network {
            case .posix(let code): return ["errno": Int(code.rawValue)]
            case .dns: return ["dns": true]
            case .tls: return ["tls": true]
            default: break
            }
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, let raw = Int32(exactly: ns.code), POSIXErrorCode(rawValue: raw) != nil { return ["errno": Int(raw)] }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return facts(underlying, depth: depth + 1) }
        return [:]
    }
}
