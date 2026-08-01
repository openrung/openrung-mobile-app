import Foundation

/// Native VPN telemetry outbox in the App Group container, stored as append-only NDJSON (one
/// event per line). PacketTunnel heartbeat/session events use this queue; React Native
/// speed-test telemetry goes directly through `OpenRungBroker`.
///
/// Appending encodes and writes ONE event; the previous single-JSON-array format decoded and
/// re-encoded the entire queue (up to 500 events, hundreds of KB) on every enqueue — an O(n²)
/// CPU/memory pattern inside the extension's ~50 MB jetsam budget, worst exactly when a blocked
/// network keeps the queue full. Full rewrites now happen only on upload commits, geo
/// back-patches, and occasional compaction; a torn final line from an extension kill is skipped
/// on read. A legacy array-format file is migrated transparently on first touch.
/// Read-modify-write remains coordinated and atomic. Port of the outbox half of Android
/// `TelemetryManager`.
enum TelemetryOutbox {
    private static let fileURL: URL? = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)?
        .appendingPathComponent(AppConfig.telemetryOutboxFilename)

    /// Appends since the last full rewrite (process-local; only the extension writes). Once the
    /// file could hold twice the in-memory cap, the next enqueue compacts it.
    private static var uncompactedAppends = 0

    static func enqueue(_ event: TelemetryEvent) {
        guard let url = fileURL, var line = try? JSONEncoder().encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            if isLegacyArrayFile(writeURL) || uncompactedAppends >= TelemetryOutboxState.maxQueued {
                // Migrate/compact: fold the new event in through a full rewrite.
                let events = TelemetryOutboxState.appended(decodeEvents(at: writeURL), event)
                write(events, to: writeURL)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: writeURL) else {
                // File missing (first event): create it with the single line.
                try? line.write(to: writeURL, options: .atomic)
                uncompactedAppends += 1
                return
            }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            uncompactedAppends += 1
        }
    }

    static func peek(max: Int) -> [TelemetryEvent] {
        Array(read().prefix(max))
    }

    static func remove(ids: Set<String>) {
        guard ids.isEmpty == false else { return }
        mutate { TelemetryOutboxState.removing($0, ids: ids) }
    }

    static func applyGeoAttributes(_ attributes: [String: String], toSessionId sessionId: String) {
        mutate { TelemetryOutboxState.applyingGeoAttributes($0, attributes, toSessionId: sessionId) }
    }

    // MARK: - Coordinated file access

    static func read() -> [TelemetryEvent] {
        guard let url = fileURL else { return [] }
        var events: [TelemetryEvent] = []
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
            events = decodeEvents(at: readURL)
        }
        return events
    }

    /// Full read-transform-rewrite; reserved for the rare mutations (upload commit, geo
    /// back-patch) that genuinely touch the whole queue.
    private static func mutate(_ transform: ([TelemetryEvent]) -> [TelemetryEvent]) {
        guard let url = fileURL else { return }
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            write(transform(decodeEvents(at: writeURL)), to: writeURL)
        }
    }

    /// Must run inside a coordination block.
    private static func write(_ events: [TelemetryEvent], to url: URL) {
        let encoder = JSONEncoder()
        var data = Data()
        for event in events {
            guard let line = try? encoder.encode(event) else { continue }
            data.append(line)
            data.append(UInt8(ascii: "\n"))
        }
        try? data.write(to: url, options: .atomic)
        uncompactedAppends = 0
    }

    /// Must run inside a coordination block. Decodes NDJSON, or the legacy array format, capped
    /// at the queue maximum (newest kept).
    private static func decodeEvents(at url: URL) -> [TelemetryEvent] {
        guard let data = try? Data(contentsOf: url), data.isEmpty == false else { return [] }
        let decoder = JSONDecoder()
        let events: [TelemetryEvent]
        if data.first == UInt8(ascii: "[") {
            events = (try? decoder.decode([TelemetryEvent].self, from: data)) ?? []
        } else {
            events = data.split(separator: UInt8(ascii: "\n")).compactMap {
                try? decoder.decode(TelemetryEvent.self, from: $0)
            }
        }
        return Array(events.suffix(TelemetryOutboxState.maxQueued))
    }

    /// Must run inside a coordination block. Cheap first-byte sniff for the pre-NDJSON format.
    private static func isLegacyArrayFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let first = try? handle.read(upToCount: 1), let byte = first.first else { return false }
        return byte == UInt8(ascii: "[")
    }
}
