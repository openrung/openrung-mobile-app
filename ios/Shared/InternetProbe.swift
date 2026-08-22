import Foundation
import Network

public struct InternetProbeResult: Sendable, Equatable {
    public let endpoint: String
    public let durationMs: Int64
}

public enum InternetProbeError: LocalizedError {
    case unreachable(Error?)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let underlying):
            let suffix = underlying.map { ": \($0.localizedDescription)" } ?? ""
            return "VPN started, but the internet probe failed\(suffix)"
        }
    }

    var underlyingError: Error? {
        guard case .unreachable(let underlying) = self else { return nil }
        return underlying
    }
}

/// Shared constants for the internet probes. Apple deliberately excludes a
/// PacketTunnelProvider's own URLSession traffic from its TUN; the extension therefore uses
/// `PacketTunnelInternetProbe`, backed by `createTCPConnectionThroughTunnel`, whenever the
/// result is used to classify a Reality/WSS path.
public enum InternetProbe {
    // Through-tunnel endpoints only. Every hostname here MUST also appear in
    // ProbeTargets.ruleDomainSuffixes so the emitted config pins its DNS and routing through
    // the proxy ahead of any country-bypass rule.
    public static let defaultEndpoints = ProbeTargets.tunnelProbeURLs

    public static func acceptsHTTPStatus(_ status: Int) -> Bool {
        (200..<300).contains(status)
    }
}

/// Marks a failure of the fresh-DNS stage of tunnel verification. `underlying` carries the real
/// network error for classification/allow-listing; the wrapper only tells the caller that the
/// resolver path (not the HTTP path) is what failed, so it can rotate the DoH resolver before
/// the next attempt.
public struct DnsPathUnverifiedError: Error {
    public let underlying: Error

    public init(underlying: Error) {
        self.underlying = underlying
    }
}

/// Positive allow-list for failures that actually demonstrate a remote network/data-path problem.
/// Unknown, permission, configuration, runtime and platform errors fail local/closed and therefore
/// can never unlock WSS fallback or advance to another signed front.
func isGenuineRemoteDataPathFailure(_ error: Error, depth: Int = 0) -> Bool {
    guard depth < 8 else { return false }
    if let dnsPathError = error as? DnsPathUnverifiedError {
        return isGenuineRemoteDataPathFailure(dnsPathError.underlying, depth: depth + 1)
    }
    if let probeError = error as? InternetProbeError {
        guard let underlying = probeError.underlyingError else { return false }
        return isGenuineRemoteDataPathFailure(underlying, depth: depth + 1)
    }
    if let reachabilityError = error as? RelayReachabilityError {
        return reachabilityError == .timeout
    }
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .secureConnectionFailed,
             .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired, .badServerResponse,
             .zeroByteResource, .resourceUnavailable, .httpTooManyRedirects,
             .redirectToNonExistentLocation, .cannotLoadFromNetwork,
             .cannotDecodeRawData, .cannotDecodeContentData, .cannotParseResponse:
            return true
        default:
            return false
        }
    }
    if let networkError = error as? NWError {
        switch networkError {
        case .dns, .tls:
            return true
        case .posix(let code):
            return isRemotePOSIXFailure(code)
        case .wifiAware(_):
            return false
        @unknown default:
            return false
        }
    }
    if let posixError = error as? POSIXError {
        return isRemotePOSIXFailure(posixError.code)
    }
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain,
       let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
        return isRemotePOSIXFailure(code)
    }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
        return isGenuineRemoteDataPathFailure(underlying, depth: depth + 1)
    }
    return false
}

private func isRemotePOSIXFailure(_ code: POSIXErrorCode) -> Bool {
    switch code {
    case .ECONNABORTED, .ECONNREFUSED, .ECONNRESET, .EHOSTDOWN, .EHOSTUNREACH,
         .ENETDOWN, .ENETRESET, .ENETUNREACH, .EPIPE, .ETIMEDOUT:
        return true
    default:
        return false
    }
}

/// Pure threshold state used by the active WSS health loop and hostless tests.
struct TunnelHealthFailureThreshold: Equatable, Sendable {
    let requiredFailures: Int
    private(set) var consecutiveFailures = 0

    init(requiredFailures: Int = 3) {
        precondition(requiredFailures > 0)
        self.requiredFailures = requiredFailures
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordRemoteFailure() -> Bool {
        consecutiveFailures = min(consecutiveFailures + 1, requiredFailures)
        return consecutiveFailures >= requiredFailures
    }
}
