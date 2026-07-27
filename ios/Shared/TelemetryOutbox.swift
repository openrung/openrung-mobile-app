import Foundation

/// Native VPN telemetry outbox backed by a single JSON file in the App Group container.
/// PacketTunnel heartbeat/session events use this queue; React Native speed-test telemetry goes
/// directly through `OpenRungBroker`. Read-modify-write remains coordinated and atomic.
/// Port of the outbox half of Android `TelemetryManager`.
enum TelemetryOutbox {
    private static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupIdentifier)?
            .appendingPathComponent(AppConfig.telemetryOutboxFilename)
    }

    static func enqueue(_ event: TelemetryEvent) {
        mutate { TelemetryOutboxState.appended($0, event) }
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
            guard let data = try? Data(contentsOf: readURL) else { return }
            events = (try? JSONDecoder().decode([TelemetryEvent].self, from: data)) ?? []
        }
        return events
    }

    private static func mutate(_ transform: ([TelemetryEvent]) -> [TelemetryEvent]) {
        guard let url = fileURL else { return }
        var coordinatorError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinatorError) { writeURL in
            let current: [TelemetryEvent]
            if let data = try? Data(contentsOf: writeURL) {
                current = (try? JSONDecoder().decode([TelemetryEvent].self, from: data)) ?? []
            } else {
                current = []
            }
            let updated = transform(current)
            if let data = try? JSONEncoder().encode(updated) {
                try? data.write(to: writeURL, options: .atomic)
            }
        }
    }
}
