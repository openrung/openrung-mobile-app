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

/// The ordered discovery endpoints for one request, plus whether `urls[0]` is a genuine user
/// override. Built by `BrokerClient.candidates` and consumed by `BrokerClient.firstReachable`;
/// carrying the flag alongside the list keeps the two from being computed inconsistently.
public struct BrokerCandidates: Sendable {
    /// Ordered discovery candidates.
    public let urls: [URL]
    /// True when `urls[0]` is a genuine user override — a primary that is not one of the built-in
    /// defaults. `firstReachable` then tries it strictly first (full per-attempt timeout) and only
    /// races the remaining defaults after it fails, so a custom broker that is merely slower than
    /// the stagger is never silently outrun by a default front.
    public let overrideFirst: Bool

    public init(urls: [URL], overrideFirst: Bool = false) {
        self.urls = urls
        self.overrideFirst = overrideFirst
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

    public func listRelays(limit: Int = 5, clientID: String? = nil, sessionID: String? = nil) async throws -> RelayListResponse {
        let url = try BrokerClient.relaysURL(brokerURL: baseURL, limit: limit)

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

        return try decoder.decode(RelayListResponse.self, from: data)
    }

    /// Builds the ordered broker candidate list, de-duplicated while preserving order. `primary` is
    /// tried FIRST only when it is a genuine override — i.e. not already one of the `fallbacks` —
    /// and only such an override sets `overrideFirst`, giving it the strict head phase described on
    /// `BrokerCandidates`. A persisted value that merely echoes a built-in default must NOT reorder
    /// the defaults' preferred (HTTPS-first) ordering (or claim the override phase). Pure and
    /// side-effect free so it is unit-testable.
    public static func candidates(primary: URL?, fallbacks: [URL]) -> BrokerCandidates {
        var ordered: [URL] = []
        var overrideFirst = false
        if let primary, fallbacks.contains(primary) == false {
            ordered.append(primary)
            overrideFirst = true
        }
        for fallback in fallbacks where ordered.contains(fallback) == false {
            ordered.append(fallback)
        }
        return BrokerCandidates(urls: ordered, overrideFirst: overrideFirst)
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
    ///  6. When `candidates.overrideFirst` is set, `urls[0]` is a GENUINE user override and racing
    ///     it would betray the user's choice: a custom broker that is merely slower than the
    ///     stagger would silently lose to a default front. The override is therefore attempted
    ///     strictly first, alone, with its full per-attempt timeout — no default is contacted
    ///     while it is pending — and it wins on any success, exactly like the old sequential loop.
    ///     Only when the override FAILS does the race of points 1–5 start over the REMAINING
    ///     candidates (the first of them immediately, the next one stagger later, and so on). If
    ///     the override and every remaining candidate fail, the override's error is rethrown — it
    ///     is `urls[0]`, so point 4's diagnostic is unchanged.
    ///
    /// Honors task cancellation like the old sequential loop: cancelling the surrounding task
    /// cancels every in-flight attempt and rethrows `CancellationError`, never a per-attempt error.
    public static func firstReachable(
        candidates: BrokerCandidates,
        limit: Int = 5,
        clientID: String? = nil,
        sessionID: String? = nil,
        session: URLSession = .shared
    ) async throws -> BrokerFetch {
        try await firstReachable(candidates: candidates) { url in
            try await BrokerClient(baseURL: url, session: session)
                .listRelays(limit: limit, clientID: clientID, sessionID: sessionID)
        }
    }

    /// Core behind `firstReachable` with the per-candidate fetch injectable and the stagger
    /// overridable, so the override / stagger / first-success / all-fail semantics are
    /// unit-testable (see `BrokerClientTests`) without real sockets or real 2.5 s staggers.
    static func firstReachable(
        candidates: BrokerCandidates,
        staggerMs: UInt64 = AppConfig.discoveryStaggerMs,
        attempt: @escaping @Sendable (URL) async throws -> RelayListResponse
    ) async throws -> BrokerFetch {
        try Task.checkCancellation()
        guard candidates.urls.isEmpty == false else {
            throw BrokerClientError.invalidResponse
        }

        if candidates.overrideFirst {
            let overrideURL = candidates.urls[0]
            let overrideError: Error
            do {
                // Strict override phase (spec point 6): one plain attempt, full timeout, no race.
                return BrokerFetch(brokerURL: overrideURL, response: try await attempt(overrideURL))
            } catch {
                // The caller went away: rethrow its cancellation, not the override's failure.
                try Task.checkCancellation()
                overrideError = error
            }
            let remaining = Array(candidates.urls.dropFirst())
            if remaining.isEmpty {
                throw overrideError
            }
            do {
                return try await race(remaining, staggerMs: staggerMs, attempt: attempt)
            } catch is CancellationError {
                throw CancellationError() // the caller went away mid-race — not a broker diagnostic
            } catch {
                // All-fail keeps surfacing candidates[0]'s — the override's — error (spec point 4).
                throw overrideError
            }
        }
        return try await race(candidates.urls, staggerMs: staggerMs, attempt: attempt)
    }

    /// The staggered-race core (spec points 1–5), sans override handling.
    private static func race(
        _ candidates: [URL],
        staggerMs: UInt64,
        attempt: @escaping @Sendable (URL) async throws -> RelayListResponse
    ) async throws -> BrokerFetch {
        try await withThrowingTaskGroup(
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
                            nanoseconds: UInt64(index) * staggerMs * 1_000_000
                        )
                    }
                    if Task.isCancelled {
                        // The race already settled (or the caller stopped the tunnel) while this
                        // attempt was still waiting its turn — never contact the endpoint.
                        return (index, .failure(CancellationError()))
                    }
                    do {
                        let response = try await attempt(url)
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
