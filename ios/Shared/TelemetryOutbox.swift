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

    /// Approximate line count of the outbox file (process-local; only the extension writes).
    /// Initialized by COUNTING the file on first touch — a per-launch zero would let the file
    /// grow without bound across extension restarts that each append fewer than the compaction
    /// threshold. Refreshed by every full rewrite; once the file could hold twice the in-memory
    /// cap, the next enqueue compacts it.
    private static var fileLineCount = -1

    static func enqueue(_ event: TelemetryEvent) {
        guard let url = fileURL, var line = try? JSONEncoder().encode(event) else { return }
        line.append(UInt8(ascii: "\n"))
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            if fileLineCount < 0 {
                fileLineCount = countLines(at: writeURL)
            }
            if isLegacyArrayFile(writeURL) || fileLineCount >= 2 * TelemetryOutboxState.maxQueued {
                // Migrate/compact: fold the new event in through a full rewrite.
                let events = TelemetryOutboxState.appended(decodeEvents(at: writeURL), event)
                write(events, to: writeURL)
                return
            }
            guard let handle = try? FileHandle(forWritingTo: writeURL) else {
                // File missing (first event): create it with the single line.
                try? line.write(to: writeURL, options: .atomic)
                fileLineCount = 1
                return
            }
            defer { try? handle.close() }
            repairTornTail(handle)
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            fileLineCount += 1
        }
    }

    /// Must run inside a coordination block. A write torn by an extension kill can leave the
    /// final line without its newline; appending straight onto it would fuse two events into
    /// one undecodable line, losing both. Truncate back to the last complete line first.
    private static func repairTornTail(_ handle: FileHandle) {
        guard let end = try? handle.seekToEnd(), end > 0 else { return }
        try? handle.seek(toOffset: end - 1)
        guard let last = try? handle.read(upToCount: 1), last.first != UInt8(ascii: "\n") else { return }
        try? handle.seek(toOffset: 0)
        let data = (try? handle.readToEnd()) ?? Data()
        let keep = data.lastIndex(of: UInt8(ascii: "\n")).map { UInt64($0) + 1 } ?? 0
        try? handle.truncate(atOffset: keep)
    }

    /// Must run inside a coordination block.
    private static func countLines(at url: URL) -> Int {
        guard let data = try? Data(contentsOf: url) else { return 0 }
        return data.reduce(into: 0) { count, byte in
            if byte == UInt8(ascii: "\n") { count += 1 }
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
        fileLineCount = events.count
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
