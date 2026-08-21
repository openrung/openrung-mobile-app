import Foundation

/// PacketTunnel façade combining session, device attributes, and native VPN telemetry. The
/// outbox — persistence in the App Group container, caps, upload batching, heartbeat
/// piggybacking, and brokerapi posting — is the shared Go implementation behind
/// `TelemetryOutboxHandling` (`android/punchbridge/telemetry_binding.go`, the same queue policy
/// every OpenRung client runs); this file only decides WHAT to record and hands fully-formed
/// events over. The app process reads only the active session ID through
/// `OpenRungVpn.getIdentity`; React Native constructs and sends speed-test events through the
/// separate `OpenRungBroker` module. Port of Android `TelemetryManager`.
enum TelemetryManager {
    /// Traffic counters for the active session, kept in memory only: the engine, the heartbeat
    /// loop, and endSession all run in the packet tunnel extension, so nothing needs to cross
    /// the app-group boundary (the app process never reports these measurements).
    private static let trafficLock = NSLock()
    private static var sessionTraffic: TrafficCounters?

    /// The bound outbox, opened once per process. Compiling this file into a target without
    /// Libbox fails loudly here — the manager cannot function without the engine's outbox.
    private static let outbox: any TelemetryOutboxHandling = NativeTelemetryOutbox()

    private static let eventEncoder = JSONEncoder()

    static func clientId() -> String {
        ClientIdentity.getOrCreate()
    }

    @discardableResult
    static func beginSession(brokerURL: String) -> TelemetrySession {
        let session = TelemetrySession(
            id: UUID().uuidString,
            clientId: clientId(),
            brokerURL: brokerURL,
            startedElapsedMs: MonotonicClock.nowMs()
        )
        resetTrafficCounters()
        TelemetrySessionStore.save(session)
        return session
    }

    /// Records the tunnel's traffic counters for the active session. Reported values must be
    /// cumulative since the engine started; the high-water mark is kept so a counter reset
    /// (engine restart) never regresses what the session already reported.
    /// Port of Android `TelemetryManager.updateTrafficCounters`.
    static func updateTrafficCounters(bytesSent: Int64, bytesReceived: Int64) {
        trafficLock.lock()
        defer { trafficLock.unlock() }
        sessionTraffic = TrafficCounters(
            bytesSent: max(bytesSent, sessionTraffic?.bytesSent ?? 0),
            bytesReceived: max(bytesReceived, sessionTraffic?.bytesReceived ?? 0)
        )
    }

    private static func trafficCounters() -> TrafficCounters? {
        trafficLock.lock()
        defer { trafficLock.unlock() }
        return sessionTraffic
    }

    /// Cumulative session counters as last pushed by the engine (nil before the first push).
    /// The tunnel health monitor compares successive values to skip probing while traffic is
    /// demonstrably flowing.
    static func currentTrafficCounters() -> TrafficCounters? {
        trafficCounters()
    }

    private static func resetTrafficCounters() {
        trafficLock.lock()
        defer { trafficLock.unlock() }
        sessionTraffic = nil
    }

    static func activeSession() -> TelemetrySession? {
        TelemetrySessionStore.current()
    }

    /// Routes the still-current session through the broker front that won verified discovery.
    /// The expected ID prevents a cancelled connect epoch from overwriting its successor's route.
    @discardableResult
    static func updateBrokerURL(_ brokerURL: String, forSessionId sessionId: String) -> Bool {
        guard var session = TelemetrySessionStore.current(), session.id == sessionId else {
            return false
        }
        session.brokerURL = brokerURL
        TelemetrySessionStore.save(session)
        return true
    }

    static func markConnected(relayId: String) {
        guard var session = TelemetrySessionStore.current() else { return }
        session.relayId = relayId
        session.connectedElapsedMs = MonotonicClock.nowMs()
        TelemetrySessionStore.save(session)
    }

    static func setGeoInfo(_ geo: ClientGeoInfo) {
        guard var session = TelemetrySessionStore.current() else { return }
        let attributes = geo.telemetryAttributes()
        session.geoAttributes = attributes
        TelemetrySessionStore.save(session)
        // Back-patch the session's already-queued events so records from before the public-IP
        // lookup resolved still carry the geo attributes. The bound outbox never patches
        // application_connection rows.
        if attributes.isEmpty == false,
           let encoded = try? eventEncoder.encode(attributes),
           let json = String(data: encoded, encoding: .utf8) {
            outbox.applySessionAttributes(sessionId: session.id, attributesJson: json)
        }
        record("client_geo_resolved")
    }

    static func record(
        _ event: String,
        relayId: String? = nil,
        attributes: [String: String] = [:],
        measurements: [String: Int64] = [:]
    ) {
        guard let session = TelemetrySessionStore.current() else { return }
        var merged = DeviceAttributes.current()
        merged.merge(session.geoAttributes) { _, new in new }
        merged.merge(attributes) { _, new in new }
        enqueue(
            TelemetryEvent(
                eventId: UUID().uuidString,
                event: event,
                occurredAt: iso8601Now(),
                clientId: session.clientId,
                sessionId: session.id,
                relayId: relayId ?? session.relayId,
                attributes: merged,
                measurements: measurements
            )
        )
    }

    private static func enqueue(_ event: TelemetryEvent) {
        guard
            let encoded = try? eventEncoder.encode(event),
            let json = String(data: encoded, encoding: .utf8)
        else { return }
        _ = outbox.enqueue(json)
    }

    @discardableResult
    static func endSession(reason: String) -> String? {
        guard let session = TelemetrySessionStore.current() else { return nil }
        let now = MonotonicClock.nowMs()
        var measurements: [String: Int64] = ["session_duration_ms": max(now - session.startedElapsedMs, 0)]
        if let connected = session.connectedElapsedMs {
            measurements["connection_duration_ms"] = max(now - connected, 0)
        }
        if let traffic = trafficCounters() {
            measurements.merge(traffic.measurements()) { _, new in new }
        }
        record("connection_ended", relayId: session.relayId, attributes: ["reason": reason], measurements: measurements)
        resetTrafficCounters()
        TelemetrySessionStore.save(nil)
        return session.brokerURL
    }

    /// Sends a heartbeat while draining queued events in FIFO, identity-homogeneous batches. The
    /// bound outbox lets the queue head piggyback only when it has the heartbeat's exact
    /// client/session pair, so historical backlog cannot delay heartbeat cadence. Best-effort:
    /// failures leave the current queued batch and everything after it.
    static func sendHeartbeat() async {
        guard let session = TelemetrySessionStore.current() else { return }

        var attributes = DeviceAttributes.current()
        attributes.merge(session.geoAttributes) { _, new in new }
        guard
            let heartbeat = buildSessionHeartbeat(
                session: session,
                occurredAt: iso8601Now(),
                elapsedRealtimeMs: MonotonicClock.nowMs(),
                attributes: attributes,
                trafficCounters: trafficCounters()
            ),
            let encoded = try? eventEncoder.encode(heartbeat),
            let heartbeatJson = String(data: encoded, encoding: .utf8)
        else { return }

        let brokerURL = session.brokerURL
        let outcome = await runUpload {
            outbox.sendHeartbeat(brokerURL: brokerURL, heartbeatJson: heartbeatJson)
        }
        guard outcome.succeeded, outcome.pendingCount > 0 else { return }
        try? await flush(brokerURL: brokerURL)
    }

    static func flush(brokerURL: String) async throws {
        while true {
            try Task.checkCancellation()
            let outcome = await runUpload {
                outbox.flushNextBatch(brokerURL: brokerURL)
            }
            // A cancelled caller aborted the request above; surface its own cancellation rather
            // than a broker failure, exactly like the per-operation transport used to.
            try Task.checkCancellation()
            guard outcome.succeeded else {
                throw outcome.failure(operationName: "native telemetry upload")
            }
            if outcome.pendingCount == 0 { return }
        }
    }

    /// Runs one blocking native upload with the same cancellation contract the per-operation
    /// transport used to provide: cancelling the awaiting task aborts the in-flight request
    /// (tunnel shutdown drains the heartbeat task and must never wait out an unresponsive
    /// broker), the blocked call returns promptly with the cancelled outcome, and the shared
    /// outbox stays open — aborted uploads commit nothing and retry later.
    private static func runUpload(
        _ call: @escaping @Sendable () -> NativeTelemetryFlushOutcome
    ) async -> NativeTelemetryFlushOutcome {
        await withTaskCancellationHandler {
            await Task.detached { call() }.value
        } onCancel: {
            outbox.abortUploads()
        }
    }

    // Constructing an ISO8601DateFormatter per event costs far more than formatting with one;
    // the class is documented thread-safe.
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func iso8601Now() -> String {
        iso8601Formatter.string(from: Date())
    }
}
