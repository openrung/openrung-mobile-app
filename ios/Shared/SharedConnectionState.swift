import Foundation

/// App-group-backed connection state shared between the PacketTunnel extension (the writer) and
/// the SwiftUI app (the reader). Each mutation persists a `ConnectionStateSnapshot` to the shared
/// `UserDefaults` and posts a Darwin notification so the app can re-read. Port of the cross-process
/// half of Android `OpenRungStatusStore`.
enum SharedConnectionState {
    private static let key = "connection_state"

    // One suite instance for the process lifetime: the computed-property form re-registered a
    // fresh UserDefaults with cfprefsd on every read/write.
    private static let defaults: UserDefaults? = UserDefaults(suiteName: AppConfig.appGroupIdentifier)

    /// Extension-side write coalescing. Every flush is a full snapshot encode + UserDefaults
    /// write + a cross-process Darwin wakeup of the app, and a connect burst appends dozens of
    /// log lines in a couple of seconds. Log-only mutations therefore batch on this serial
    /// queue and flush at most every 250 ms; status/relay/error/recents changes flush
    /// immediately and carry any pending log lines with them (the queue is FIFO, so ordering
    /// between the two kinds is preserved). Worst case on an extension kill: the final ≤250 ms
    /// of log lines are lost — terminal transitions are non-coalescable, so never the outcome.
    private static let mutationQueue = DispatchQueue(label: "com.openrung.app.shared-connection-state")
    private static var pendingSnapshot: ConnectionStateSnapshot?
    private static var logFlushScheduled = false

    static func snapshot() -> ConnectionStateSnapshot {
        guard
            let data = defaults?.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(ConnectionStateSnapshot.self, from: data)
        else {
            return ConnectionStateSnapshot(brokerURL: AppConfig.defaultBrokerURL.absoluteString)
        }
        return snapshot
    }

    /// What the app shows on a cold launch: a stale CONNECTED never survives, and relay details
    /// (which could leak a prior relay) are dropped until re-resolved.
    static func sanitizedForColdStart() -> ConnectionStateSnapshot {
        var snapshot = snapshot()
        if snapshot.status == .connected {
            snapshot.status = .disconnected
        }
        snapshot.relayLabel = nil
        snapshot.relayName = nil
        return snapshot
    }

    // MARK: - Mutators (called by the extension)

    static func setBrokerURL(_ url: String) {
        mutate { $0.brokerURL = url }
    }

    static func setRelayLabel(_ label: String?) {
        mutate { $0.relayLabel = label }
    }

    static func recordRecent(_ node: RecentNode) {
        mutate { snapshot in
            snapshot.recentRegions = (
                [node] +
                    snapshot.recentRegions.filter { recent in
                        recent.relayId != node.relayId &&
                            !(recent.relayId == nil && recent.countryCode == node.countryCode)
                    }
            )
                .prefix(AppConfig.maxRecents)
                .map { $0 }
        }
    }

    static func clearError() {
        mutate { $0.lastError = nil }
    }

    static func setStatus(
        _ status: ConnectionStatus,
        relayName: String? = nil,
        clearRelayLabel: Bool = false,
        clearError: Bool = false
    ) {
        mutate { snapshot in
            snapshot.status = status
            // While connected, nil keeps the current name (mirroring the Android store's
            // default) so a mid-session status re-assert never blanks the UI; every other
            // status always clears it.
            snapshot.relayName = status == .connected ? (relayName ?? snapshot.relayName) : nil
            if clearRelayLabel { snapshot.relayLabel = nil }
            if clearError { snapshot.lastError = nil }
            snapshot.logLines = ActivityLog.appended(snapshot.logLines, ActivityLog.line(status.displayLabel))
        }
    }

    static func appendLog(_ message: String) {
        mutate(coalescable: true) { snapshot in
            snapshot.logLines = ActivityLog.appended(snapshot.logLines, ActivityLog.line(message))
        }
    }

    static func fail(_ message: String) {
        mutate { snapshot in
            snapshot.status = .failed
            snapshot.lastError = message
            snapshot.relayLabel = nil
            snapshot.relayName = nil
            snapshot.logLines = ActivityLog.appended(snapshot.logLines, ActivityLog.line("error: \(message)"))
        }
    }

    // MARK: - Persistence + notification

    private static func mutate(
        coalescable: Bool = false,
        _ transform: @escaping (inout ConnectionStateSnapshot) -> Void
    ) {
        mutationQueue.async {
            var pending = pendingSnapshot ?? snapshot()
            transform(&pending)
            pendingSnapshot = pending
            if coalescable {
                scheduleLogFlush()
            } else {
                flushPendingOnQueue()
            }
        }
    }

    /// Must run on `mutationQueue`.
    private static func scheduleLogFlush() {
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        mutationQueue.asyncAfter(deadline: .now() + .milliseconds(250)) {
            flushPendingOnQueue()
        }
    }

    /// Must run on `mutationQueue`.
    private static func flushPendingOnQueue() {
        logFlushScheduled = false
        guard let snapshot = pendingSnapshot else { return }
        pendingSnapshot = nil
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
        postDarwinNotification()
    }

    static func postDarwinNotification() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppConfig.darwinNotificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
