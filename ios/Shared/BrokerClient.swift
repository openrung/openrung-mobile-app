import Foundation

// BrokerClientError moved to BrokerClientError.swift so FailureClassifier and its tests can depend
// on it without the rest of the networking stack.

/// A successful relay fetch together with the broker endpoint that served it.
public struct BrokerFetch: Sendable {
    public let brokerURL: URL
    public let response: RelayListResponse

    public init(brokerURL: URL, response: RelayListResponse) {
        self.brokerURL = brokerURL
        self.response = response
    }
}

public struct BrokerClient: Sendable {
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Verifier over the operator keys pinned in AppConfig. Built once — verification itself is
    /// per-response (`listRelays`), on the raw bytes, before any JSON decode.
    private static let relayListVerifier = RelayListVerifier(keys: AppConfig.relaySigningKeys)

    public func listRelays(limit: Int = 5, clientID: String? = nil, sessionID: String? = nil) async throws -> RelayListResponse {
        // The effective limit is what the query carries; the broker echoes it back inside the
        // signed body and the verifier rejects any mismatch (anti variant-steering, signing spec
        // §2.2), so it must be computed once and used for both the URL and the check.
        let effectiveLimit = max(limit, 1)
        let url = try BrokerClient.relaysURL(brokerURL: baseURL, limit: effectiveLimit)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        // Real-time data served with a long max-age by the broker edge — bypass URLSession's
        // cache so a newly registered relay shows up on the next fetch, not hours later.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // Per-attempt timeout, matching the other clients (TS REQUEST_TIMEOUT_MS = 15 s, Android
        // readTimeout = 15 s) — without it URLSession's ~60 s default would let a hung attempt
        // undo the staggered-race latency win.
        request.timeoutInterval = 15
        if let clientID {
            request.setValue(clientID, forHTTPHeaderField: "X-OpenRung-Client-ID")
        }
        if let sessionID {
            request.setValue(sessionID, forHTTPHeaderField: "X-OpenRung-Session-ID")
        }
        request.setValue(DeviceAttributes.appVersion, forHTTPHeaderField: "X-OpenRung-App-Version")
        request.setValue(DeviceAttributes.osVersion, forHTTPHeaderField: "X-OpenRung-iOS-Version")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrokerClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BrokerClientError.httpStatus(httpResponse.statusCode)
        }

        // Authenticate BEFORE decoding: Ed25519 over the exact raw bytes URLSession handed us
        // (post transfer-decoding, equal to origin bytes), against the pinned operator keys —
        // never over re-serialized parsed JSON (signing spec §5.2). The header MUST be read via
        // value(forHTTPHeaderField:), which matches case-insensitively; allHeaderFields
        // subscripting is case-sensitive and silently misses the lowercased names HTTP/2+ puts
        // on the wire. Loopback candidates are the sole exemption (local dev broker, mirroring
        // the desktop client's EnforceSecureBrokerURL allowance); every other candidate —
        // including user overrides — fails without a valid signature. The verified key id is
        // dropped for now: the §5.2 keyIdUsed telemetry ships with the client cache phase.
        if RelayListVerifier.isLoopbackHost(url.host) == false {
            _ = try BrokerClient.relayListVerifier.verify(
                body: data,
                signatureHeader: httpResponse.value(forHTTPHeaderField: RelayListVerifier.signatureHeaderName),
                channel: .api,
                requestedLimit: effectiveLimit
            )
        }

        return try decoder.decode(RelayListResponse.self, from: data)
    }

    /// Builds the ordered broker candidate list, de-duplicated while preserving order. `primary` is
    /// tried FIRST only when it is a genuine override — i.e. not already one of the `fallbacks`. A
    /// persisted value that merely echoes a built-in default must NOT reorder the defaults' preferred
    /// (HTTPS-first) ordering. Pure and side-effect free so it is unit-testable.
    public static func candidates(primary: URL?, fallbacks: [URL]) -> [URL] {
        var ordered: [URL] = []
        if let primary, fallbacks.contains(primary) == false {
            ordered.append(primary)
        }
        for fallback in fallbacks where ordered.contains(fallback) == false {
            ordered.append(fallback)
        }
        return ordered
    }

    /// Staggered-race discovery (happy-eyeballs style) across the candidate brokers, returning the
    /// first success along with the endpoint that served it. A blocked or blackholed primary front
    /// therefore costs one `AppConfig.discoveryStaggerMs` of extra latency — not a full request
    /// timeout — before a fallback front is contacted, and never takes discovery offline as long as
    /// one candidate is reachable.
    ///
    /// Race semantics — MUST stay identical across the desktop Go client, the reference TypeScript
    /// implementation (`firstReachable` in `src/net/brokerClient.ts`), the Android Kotlin port, and
    /// this Swift port:
    ///
    ///  1. `candidates[0]` starts immediately; while no attempt has succeeded yet, every
    ///     `discoveryStaggerMs` the next not-yet-started candidate joins the race. An early FAILURE
    ///     does not accelerate the schedule — starts are driven purely by the stagger cadence
    ///     (candidate N sleeps N staggers before attempting, which is the same cadence).
    ///  2. The first SUCCESS wins and returns immediately, cancelling every other in-flight attempt
    ///     and the not-yet-started sleepers. A later candidate that succeeds first wins even while an
    ///     earlier-priority attempt is still pending: candidate order buys a head start in the race,
    ///     nothing more.
    ///  3. The per-attempt timeout is unchanged (each attempt is one `listRelays` request).
    ///  4. If EVERY candidate fails, the FIRST candidate's (the primary's) error is rethrown — the
    ///     primary's failure is the meaningful diagnostic; later fallbacks' errors are secondary.
    ///  5. With a single candidate the observable behavior equals the old sequential loop: one
    ///     attempt, no stagger sleeps, its error propagated unchanged.
    ///
    /// Honors task cancellation like the old sequential loop: cancelling the surrounding task
    /// cancels every in-flight attempt and rethrows `CancellationError`, never a per-attempt error.
    public static func firstReachable(
        candidates: [URL],
        limit: Int = 5,
        clientID: String? = nil,
        sessionID: String? = nil,
        session: URLSession = .shared
    ) async throws -> BrokerFetch {
        try Task.checkCancellation()
        guard candidates.isEmpty == false else {
            throw BrokerClientError.invalidResponse
        }

        return try await withThrowingTaskGroup(
            of: (Int, Result<BrokerFetch, Error>).self,
            returning: BrokerFetch.self
        ) { group in
            for (index, url) in candidates.enumerated() {
                group.addTask {
                    if index > 0 {
                        // Head start of the earlier candidates: candidate N joins the race N staggers
                        // after candidate 0. A win cancels this sleep (via cancelAll below), so later
                        // candidates only ever start while no attempt has succeeded yet; an early
                        // failure does NOT cut the sleep short (spec point 1).
                        try? await Task.sleep(
                            nanoseconds: UInt64(index) * AppConfig.discoveryStaggerMs * 1_000_000
                        )
                    }
                    if Task.isCancelled {
                        // The race already settled (or the caller stopped the tunnel) while this
                        // attempt was still waiting its turn — never contact the endpoint.
                        return (index, .failure(CancellationError()))
                    }
                    do {
                        let response = try await BrokerClient(baseURL: url, session: session)
                            .listRelays(limit: limit, clientID: clientID, sessionID: sessionID)
                        return (index, .success(BrokerFetch(brokerURL: url, response: response)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            // Failure of each settled attempt, index-aligned; errors[0] is the surfaced diagnostic.
            var errors = [Error?](repeating: nil, count: candidates.count)
            while let (index, outcome) = try await group.next() {
                switch outcome {
                case .success(let fetch):
                    // First success wins: cancel every other in-flight attempt (URLSession aborts
                    // the losers' requests for real) and the pending staggers (spec point 2).
                    group.cancelAll()
                    return fetch
                case .failure(let error):
                    errors[index] = error
                }
            }

            // Every candidate has started and failed. If the surrounding task was cancelled
            // mid-race the collected errors are just cancellation noise — propagate
            // CancellationError instead, exactly like the old loop's per-iteration check.
            try Task.checkCancellation()
            throw errors[0] ?? BrokerClientError.invalidResponse
        }
    }

    public static func relaysURL(brokerURL: URL, limit: Int) throws -> URL {
        let base = try BrokerEndpoint.build(base: brokerURL, appending: "api/v1/relays")
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "limit", value: String(max(limit, 1)))]
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
