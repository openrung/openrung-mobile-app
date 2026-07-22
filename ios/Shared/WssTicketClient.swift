import Foundation

struct WssSessionTicket: Equatable, Sendable {
    /// Opaque bearer credential. It must never enter a URL, log, metric or error message.
    let ticket: String
    let expiresAt: Date
    /// Broker-echoed URL, compared byte-for-byte with the selected signed front by the caller.
    let url: String

    func isFresh(at now: Date) -> Bool {
        expiresAt > now
    }
}

struct WssTicketStatusError: Error, Equatable {
    let status: Int
    let retryAfterMilliseconds: UInt64?
}

struct WssTicketPolicy: Equatable, Sendable {
    let totalDeadlineMilliseconds: UInt64
    let perAttemptMilliseconds: UInt64
    let defaultRetryAfterMilliseconds: UInt64
    let maxRetryAfterMilliseconds: UInt64

    init(
        totalDeadlineMilliseconds: UInt64 = 15_000,
        perAttemptMilliseconds: UInt64 = 5_000,
        defaultRetryAfterMilliseconds: UInt64 = 10_000,
        maxRetryAfterMilliseconds: UInt64 = 30_000
    ) {
        precondition(totalDeadlineMilliseconds > 0)
        precondition(perAttemptMilliseconds > 0)
        precondition(defaultRetryAfterMilliseconds > 0)
        precondition(maxRetryAfterMilliseconds > 0)
        self.totalDeadlineMilliseconds = totalDeadlineMilliseconds
        self.perAttemptMilliseconds = perAttemptMilliseconds
        self.defaultRetryAfterMilliseconds = defaultRetryAfterMilliseconds
        self.maxRetryAfterMilliseconds = maxRetryAfterMilliseconds
    }
}

typealias WssTicketAttempt = @Sendable (
    _ brokerURL: URL,
    _ relayID: String,
    _ frontID: String,
    _ clientID: String?,
    _ sessionID: String?,
    _ timeoutMilliseconds: UInt64
) async throws -> WssSessionTicket

/// URLSession normally follows redirects. Ticket POSTs instead retain the 3xx response so neither
/// the request body nor stable client/session identity headers can be forwarded to another origin.
final class WssRedirectRejectingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// HTTPS control-plane client for one relay/front-bound, short-lived WSS ticket.
final class WssTicketClient: @unchecked Sendable {
    private static let ticketPath = "api/v1/wss/tickets"
    private static let maxResponseBytes = 64 * 1024
    private static let maxTicketBytes = 4_096

    private let redirectDelegate: WssRedirectRejectingDelegate
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 15
        let redirectDelegate = WssRedirectRejectingDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func requestWithFailover(
        brokerURLs: [URL],
        relayID: String,
        frontID: String,
        clientID: String? = nil,
        sessionID: String? = nil
    ) async throws -> WssSessionTicket {
        try await Self.requestWithFailover(
            brokerURLs: brokerURLs,
            relayID: relayID,
            frontID: frontID,
            clientID: clientID,
            sessionID: sessionID,
            policy: WssTicketPolicy(),
            monotonicMilliseconds: {
                UInt64(max(ProcessInfo.processInfo.systemUptime * 1_000, 0))
            },
            wait: { milliseconds in
                try await Task.sleep(nanoseconds: milliseconds.multipliedReportingOverflow(by: 1_000_000).partialValue)
            },
            attempt: { [session] brokerURL, requestedRelayID, requestedFrontID, requestedClientID, requestedSessionID, timeout in
                try await Self.requestOnce(
                    session: session,
                    brokerURL: brokerURL,
                    relayID: requestedRelayID,
                    frontID: requestedFrontID,
                    clientID: requestedClientID,
                    sessionID: requestedSessionID,
                    timeoutMilliseconds: timeout
                )
            }
        )
    }

    /// Injectable orchestration core. Fronts are sequential under one deadline; only 429/503 may
    /// schedule one additional round, after a bounded Retry-After wait.
    static func requestWithFailover(
        brokerURLs: [URL],
        relayID: String,
        frontID: String,
        clientID: String?,
        sessionID: String?,
        policy: WssTicketPolicy,
        monotonicMilliseconds: @Sendable () -> UInt64,
        wait: @Sendable (UInt64) async throws -> Void,
        attempt: @escaping WssTicketAttempt
    ) async throws -> WssSessionTicket {
        guard relayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw URLError(.badURL)
        }
        guard frontID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw URLError(.badURL)
        }
        var fronts: [URL] = []
        for url in brokerURLs where fronts.contains(url) == false {
            fronts.append(url)
        }
        guard fronts.isEmpty == false else { throw URLError(.badURL) }

        let started = monotonicMilliseconds()
        let deadline = saturatedAdd(started, policy.totalDeadlineMilliseconds)
        var firstFailure: Error?
        var scheduledRetryDelay: UInt64?

        for round in 0...1 {
            for brokerURL in fronts {
                try Task.checkCancellation()
                let remaining = remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds())
                guard remaining > 0 else { throw firstFailure ?? URLError(.timedOut) }
                let attemptTimeout = min(policy.perAttemptMilliseconds, remaining)
                do {
                    return try await withTimeout(milliseconds: attemptTimeout) {
                        try await attempt(
                            brokerURL,
                            relayID,
                            frontID,
                            clientID,
                            sessionID,
                            attemptTimeout
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if firstFailure == nil { firstFailure = error }
                    if round == 0, let candidate = retryDelay(for: error, policy: policy) {
                        scheduledRetryDelay = max(scheduledRetryDelay ?? 0, candidate)
                    }
                }
            }

            if round == 1 { break }
            guard let delay = scheduledRetryDelay else {
                throw firstFailure ?? URLError(.cannotConnectToHost)
            }
            guard let firstFailure else { throw URLError(.cannotConnectToHost) }
            let remaining = remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds())
            guard delay < remaining else { throw firstFailure }
            try await wait(delay)
            try Task.checkCancellation()
            guard remainingMilliseconds(deadline: deadline, now: monotonicMilliseconds()) > 0 else {
                throw firstFailure
            }
        }
        throw firstFailure ?? URLError(.cannotConnectToHost)
    }

    static func requestOnce(
        session: URLSession,
        brokerURL: URL,
        relayID: String,
        frontID: String,
        clientID: String? = nil,
        sessionID: String? = nil,
        timeoutMilliseconds: UInt64 = 5_000,
        now: Date = Date()
    ) async throws -> WssSessionTicket {
        let request = try ticketRequest(
            brokerURL: brokerURL,
            relayID: relayID,
            frontID: frontID,
            clientID: clientID,
            sessionID: sessionID,
            timeoutMilliseconds: timeoutMilliseconds
        )

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw WssTicketStatusError(
                status: http.statusCode,
                retryAfterMilliseconds: parseRetryAfterMilliseconds(
                    http.value(forHTTPHeaderField: "Retry-After"),
                    now: now
                )
            )
        }

        var body = Data()
        body.reserveCapacity(min(maxResponseBytes, 8 * 1024))
        for try await byte in bytes {
            guard body.count < maxResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
            body.append(byte)
        }
        return try decodeTicketResponse(body, now: now)
    }

    /// Parses a bounded response without retaining attacker-controlled decoder diagnostics.
    static func decodeTicketResponse(_ body: Data, now: Date) throws -> WssSessionTicket {
        guard body.count <= maxResponseBytes else { throw URLError(.dataLengthExceedsMaximum) }
        let decoded: TicketResponse
        do {
            decoded = try JSONDecoder().decode(TicketResponse.self, from: body)
        } catch {
            // Never retain a parser error that can quote attacker-controlled body bytes.
            throw URLError(.cannotParseResponse)
        }
        let ticketSize = decoded.ticket.lengthOfBytes(using: .utf8)
        guard
            (1...maxTicketBytes).contains(ticketSize),
            // Swift treats CRLF as one extended grapheme cluster, so String.contains("\r") and
            // contains("\n") both return false for the dangerous pair. Inspect raw UTF-8 bytes.
            decoded.ticket.utf8.contains(0x0D) == false,
            decoded.ticket.utf8.contains(0x0A) == false,
            decoded.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
            let expiresAt = parseISO8601(decoded.expiresAt),
            expiresAt > now
        else {
            throw URLError(.cannotParseResponse)
        }
        return WssSessionTicket(ticket: decoded.ticket, expiresAt: expiresAt, url: decoded.url)
    }

    /// Pure request construction keeps exact ticket POST bytes and security headers testable even
    /// on URLProtocol implementations that normalize `httpBody` into an upload stream.
    static func ticketRequest(
        brokerURL: URL,
        relayID: String,
        frontID: String,
        clientID: String? = nil,
        sessionID: String? = nil,
        timeoutMilliseconds: UInt64 = 5_000
    ) throws -> URLRequest {
        let endpoint = try ticketEndpoint(for: brokerURL)
        let payload = try JSONEncoder().encode(TicketRequest(relayID: relayID, frontID: frontID))
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = TimeInterval(timeoutMilliseconds) / 1_000
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue(DeviceAttributes.appVersion, forHTTPHeaderField: "X-OpenRung-App-Version")
        request.setValue(DeviceAttributes.osVersion, forHTTPHeaderField: "X-OpenRung-iOS-Version")
        if let clientID, clientID.isEmpty == false, let sessionID, sessionID.isEmpty == false {
            request.setValue(clientID, forHTTPHeaderField: "X-OpenRung-Client-ID")
            request.setValue(sessionID, forHTTPHeaderField: "X-OpenRung-Session-ID")
        }
        return request
    }

    static func ticketEndpoint(for baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        guard
            let scheme = components.scheme?.lowercased(),
            let host = components.host,
            components.user == nil,
            components.password == nil,
            components.port == nil || (1...65_535).contains(components.port!)
        else {
            throw URLError(.badURL)
        }
        let permitted = scheme == "https" || (scheme == "http" && hostIsLoopback(host))
        guard permitted else { throw URLError(.secureConnectionFailed) }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, ticketPath].filter { $0.isEmpty == false }.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let endpoint = components.url else { throw URLError(.badURL) }
        return endpoint
    }

    static func parseRetryAfterMilliseconds(_ value: String?, now: Date) -> UInt64? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard value.isEmpty == false else { return nil }
        if value.allSatisfy(\.isNumber) {
            let seconds = UInt64(value) ?? UInt64.max
            return seconds.multipliedReportingOverflow(by: 1_000).overflow
                ? UInt64.max
                : seconds * 1_000
        }
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value), date > now {
                return UInt64(date.timeIntervalSince(now) * 1_000)
            }
        }
        return nil
    }

    private static func retryDelay(for error: Error, policy: WssTicketPolicy) -> UInt64? {
        guard let status = error as? WssTicketStatusError, status.status == 429 || status.status == 503 else {
            return nil
        }
        let requested = status.retryAfterMilliseconds.flatMap { $0 > 0 ? $0 : nil }
            ?? policy.defaultRetryAfterMilliseconds
        return min(requested, policy.maxRetryAfterMilliseconds)
    }

    private static func withTimeout<T: Sendable>(
        milliseconds: UInt64,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                let nanoseconds = milliseconds.multipliedReportingOverflow(by: 1_000_000)
                try await Task.sleep(nanoseconds: nanoseconds.overflow ? UInt64.max : nanoseconds.partialValue)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw URLError(.timedOut) }
            return first
        }
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: value) { return parsed }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func hostIsLoopback(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        if normalized == "localhost" || normalized == "::1" { return true }
        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else { return false }
        return octets.allSatisfy { UInt8($0) != nil }
    }

    private static func saturatedAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
        value.addingReportingOverflow(increment).overflow ? UInt64.max : value + increment
    }

    private static func remainingMilliseconds(deadline: UInt64, now: UInt64) -> UInt64 {
        now >= deadline ? 0 : deadline - now
    }

    private struct TicketRequest: Encodable {
        let relayID: String
        let frontID: String

        enum CodingKeys: String, CodingKey {
            case relayID = "relay_id"
            case frontID = "front_id"
        }
    }

    private struct TicketResponse: Decodable {
        let ticket: String
        let expiresAt: String
        let url: String

        enum CodingKeys: String, CodingKey {
            case ticket
            case expiresAt = "expires_at"
            case url
        }
    }
}
