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
    /// SYNCHRONOUSLY (see mutate) so a terminal state is on disk before the caller hands
    /// control back to NetworkExtension. Worst case on an extension kill: the final ≤250 ms of
    /// log lines are lost — terminal transitions are synchronous, so never the outcome.
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

    /// What the app shows on a cold launch (the rule lives on the snapshot for testability).
    static func sanitizedForColdStart() -> ConnectionStateSnapshot {
        snapshot().sanitizedForColdStart()
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
        relayClass: String? = nil,
        clearRelayLabel: Bool = false,
        clearError: Bool = false
    ) {
        mutate { snapshot in
            snapshot.apply(
                status: status,
                relayName: relayName,
                relayClass: relayClass,
                clearRelayLabel: clearRelayLabel,
                clearError: clearError
            )
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
            snapshot.applyFailure(message)
            snapshot.logLines = ActivityLog.appended(snapshot.logLines, ActivityLog.line("error: \(message)"))
        }
    }

    // MARK: - Persistence + notification

    private static func mutate(
        coalescable: Bool = false,
        _ transform: @escaping (inout ConnectionStateSnapshot) -> Void
    ) {
        if coalescable {
            mutationQueue.async {
                applyOnQueue(transform)
                scheduleLogFlush()
            }
        } else {
            // Status/error/recents writes must be DURABLE before the caller proceeds: failure
            // paths call cancelTunnelWithError or the stop completion right after, and
            // NetworkExtension may suspend the process the moment they do — an async write
            // would be lost with it. sync on the serial queue also drains any earlier queued
            // log appends first, so ordering between the two kinds is preserved.
            mutationQueue.sync {
                applyOnQueue(transform)
                flushPendingOnQueue()
            }
        }
    }

    /// Must run on `mutationQueue`.
    private static func applyOnQueue(_ transform: (inout ConnectionStateSnapshot) -> Void) {
        var pending = pendingSnapshot ?? snapshot()
        transform(&pending)
        pendingSnapshot = pending
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
