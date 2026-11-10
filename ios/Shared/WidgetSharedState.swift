import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The home-screen widget's view of the tunnel, and the app-group keys the app and the PacketTunnel
/// extension use to feed it (contract §2 / §7). The widget reads everything here and writes one
/// key of its own (`widget_rendered_face`).
///
/// The PacketTunnel extension stays the sole writer of the `connection_state` snapshot; the widget
/// decodes just its `status` (as a raw string, so this file needs nothing else from Shared/).
/// Everything the app publishes for the widget lives under its own `widget_*` keys, so an
/// app-process write can never clobber the tunnel's snapshot.
enum WidgetSharedState {
    static let appGroupIdentifier = "group.com.openrung.app"
    /// The tunnel-written `ConnectionStateSnapshot` (`SharedConnectionState`'s key; a test pins both).
    static let connectionSnapshotKey = "connection_state"
    /// App-written: the in-app language tag ('' = follow the system), mirrored from the RN store.
    static let languageTagKey = "widget_language_tag"
    /// Written by `WidgetReloadGate`: the last face WidgetKit was asked to render.
    static let lastPublishedFaceKey = "widget_last_face"
    /// Written with it: when the tunnel entered that face (seconds since 1970). Paces the widget's
    /// own refresh of a transitional face (`WidgetSelfRefresh`).
    static let lastPublishedFaceDateKey = "widget_last_face_at"
    /// App-written (`WidgetStaleTunnelMarker`): true when the OS reported the tunnel down while
    /// the snapshot still claimed it live (the extension was killed). Removed by the tunnel on
    /// its next snapshot write, so a real tunnel always supersedes it.
    static let systemTunnelDownKey = "widget_system_tunnel_down"
    /// Widget-written (the only key it writes): the face of the last timeline it built. A reload
    /// request is not a render — WidgetKit budgets and defers requests made while the app is not
    /// in the foreground — so the app re-requests while this lags (`WidgetRenderCatchUp`).
    static let renderedFaceKey = "widget_rendered_face"
    /// WidgetKit `kind` of the single widget; reload requests target exactly this.
    static let widgetKind = "OpenRungConnect"

    // One suite instance per process (see SharedConnectionState for why not a computed property).
    static let defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)

    /// Decodes only `status` out of a persisted snapshot; anything missing or undecodable reads as
    /// disconnected, the face from which a connect is offered — never a stale "connected".
    static func face(fromSnapshotData data: Data?) -> WidgetFace {
        guard let data, let partial = try? JSONDecoder().decode(StatusOnly.self, from: data) else {
            return .disconnected
        }
        return WidgetFace(statusRawValue: partial.status ?? "")
    }

    /// The face from a snapshot, overridden to disconnected while the app's stale-tunnel marker
    /// says the OS has no such tunnel.
    static func face(fromSnapshotData data: Data?, systemTunnelDown: Bool) -> WidgetFace {
        systemTunnelDown ? .disconnected : face(fromSnapshotData: data)
    }

    static func currentFace() -> WidgetFace {
        face(
            fromSnapshotData: defaults?.data(forKey: connectionSnapshotKey),
            systemTunnelDown: defaults?.bool(forKey: systemTunnelDownKey) ?? false
        )
    }

    /// How long the tunnel has been in `face`, nil when its record is for another face (or absent).
    static func age(of face: WidgetFace, now: Date = Date()) -> TimeInterval? {
        guard let defaults,
              defaults.string(forKey: lastPublishedFaceKey) == face.rawValue,
              let since = defaults.object(forKey: lastPublishedFaceDateKey) as? Double
        else { return nil }
        return now.timeIntervalSince1970 - since
    }

    static func currentLanguageTag() -> String {
        defaults?.string(forKey: languageTagKey) ?? ""
    }

    /// The face of the last timeline the widget built, nil until it has built one.
    static func renderedFace() -> WidgetFace? {
        defaults?.string(forKey: renderedFaceKey).flatMap(WidgetFace.init(rawValue:))
    }

    /// Called by the widget's timeline provider for every real (non-preview) timeline.
    static func recordRenderedFace(_ face: WidgetFace) {
        defaults?.set(face.rawValue, forKey: renderedFaceKey)
    }

    private struct StatusOnly: Decodable {
        let status: String?
    }
}

/// What the widget renders for a tunnel status. `preparing` and `connecting` collapse into one face,
/// so a connect attempt costs two WidgetKit reloads (connecting, connected) rather than three and a
/// recovery that re-walks preparing → connecting costs none.
enum WidgetFace: String, Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed

    /// From a `ConnectionStatus.rawValue`; anything unrecognised is disconnected.
    init(statusRawValue: String) {
        switch statusRawValue {
        case "preparing", "connecting": self = .connecting
        case "connected": self = .connected
        case "disconnecting": self = .disconnecting
        case "failed": self = .failed
        default: self = .disconnected
        }
    }

    /// The Connect control is offered only where a tap could start a tunnel without touching a live
    /// one; every other face opens the app instead.
    var offersConnect: Bool {
        self == .disconnected || self == .failed
    }

    /// A face the tunnel is expected to leave on its own, soon.
    var isTransitional: Bool {
        self == .connecting || self == .disconnecting
    }
}

/// The widget's own refresh of a transitional face. A reload request is the tunnel's to make, but
/// WidgetKit may defer one made while the app is not in the foreground, and nothing else would
/// then move the widget off "Connecting". So a timeline built on a transitional face asks to be
/// rebuilt: quickly at first (a connect normally settles within seconds, and the rebuilt timeline
/// on a settled face asks for nothing more), then ever more slowly, so a tunnel that stays in
/// transition cannot drain the widget's daily reload budget. Settled faces never refresh.
enum WidgetSelfRefresh {
    static let earlyDelay: TimeInterval = 10
    static let earlyWindow: TimeInterval = 60
    static let midDelay: TimeInterval = 60
    static let midWindow: TimeInterval = 600
    static let lateDelay: TimeInterval = 3600

    /// Seconds until the widget should rebuild its timeline, nil for never. `age` is how long the
    /// tunnel has been in `face`; unknown is treated as old (the slowest pace).
    static func delay(for face: WidgetFace, age: TimeInterval?) -> TimeInterval? {
        guard face.isTransitional else { return nil }
        guard let age, age >= 0 else { return lateDelay }
        if age < earlyWindow { return earlyDelay }
        if age < midWindow { return midDelay }
        return lateDelay
    }
}

/// Asks WidgetKit to reload only when the face changed since the last request (and the widget has
/// not already rendered it): WidgetKit's daily reload budget is small, and the snapshot is rewritten
/// for every log line. Runs in the tunnel extension on every snapshot flush, and every flush retires
/// the app's stale-tunnel marker: a fresh tunnel write is the truth, whatever the app concluded
/// earlier. A request made while the app is not in the foreground is budgeted and may be deferred;
/// the widget's own refresh of a transitional face (`WidgetSelfRefresh`) and `WidgetRenderCatchUp`
/// (app, the next time it is in front) cover that.
struct WidgetReloadGate {
    var readLastFace: () -> WidgetFace?
    var writeLastFace: (WidgetFace) -> Void
    var readRenderedFace: () -> WidgetFace?
    var clearStaleTunnelMarker: () -> Void
    var reload: () -> Void

    /// Returns true when a reload was requested.
    @discardableResult
    func publish(statusRawValue: String) -> Bool {
        clearStaleTunnelMarker()
        let face = WidgetFace(statusRawValue: statusRawValue)
        guard readLastFace() != face else { return false }
        writeLastFace(face)
        // The app's catch-up may have had this face rendered already (e.g. after a launch).
        guard readRenderedFace() != face else { return false }
        reload()
        return true
    }

    static let shared = WidgetReloadGate(
        readLastFace: {
            WidgetSharedState.defaults?
                .string(forKey: WidgetSharedState.lastPublishedFaceKey)
                .flatMap(WidgetFace.init(rawValue:))
        },
        writeLastFace: { face in
            WidgetSharedState.defaults?.set(face.rawValue, forKey: WidgetSharedState.lastPublishedFaceKey)
            WidgetSharedState.defaults?.set(
                Date().timeIntervalSince1970, forKey: WidgetSharedState.lastPublishedFaceDateKey
            )
        },
        readRenderedFace: { WidgetSharedState.renderedFace() },
        clearStaleTunnelMarker: {
            WidgetSharedState.defaults?.removeObject(forKey: WidgetSharedState.systemTunnelDownKey)
        },
        reload: {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
            #endif
        }
    )
}

/// The app's one widget-facing publication about the tunnel: that the OS has no live tunnel
/// although the snapshot still says so. It only ever SETS the marker (deduplicated, so a run of
/// status refreshes costs one reload); the tunnel's next write clears it.
struct WidgetStaleTunnelMarker {
    var readMarker: () -> Bool
    var writeMarker: () -> Void
    var reload: () -> Void

    /// Whether the marker applies: the OS says down while the snapshot claims a live tunnel.
    static func applies(systemTunnelIsDown: Bool, snapshotFace: WidgetFace) -> Bool {
        systemTunnelIsDown && (snapshotFace == .connected || snapshotFace == .connecting)
    }

    /// Returns true when the marker was newly set (and a reload requested).
    @discardableResult
    func publish(systemTunnelIsDown: Bool, snapshotFace: WidgetFace) -> Bool {
        guard Self.applies(systemTunnelIsDown: systemTunnelIsDown, snapshotFace: snapshotFace),
              !readMarker()
        else { return false }
        writeMarker()
        reload()
        return true
    }

    static let shared = WidgetStaleTunnelMarker(
        readMarker: { WidgetSharedState.defaults?.bool(forKey: WidgetSharedState.systemTunnelDownKey) ?? false },
        writeMarker: { WidgetSharedState.defaults?.set(true, forKey: WidgetSharedState.systemTunnelDownKey) },
        reload: {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
            #endif
        }
    )
}

/// The app's answer to WidgetKit's reload budget: a tunnel-requested reload made while the app was
/// not in the foreground (connect from the app, quit while connecting) may be deferred for a long
/// time, leaving the widget on a face the snapshot has long moved past. Reloads requested while the
/// app is in the foreground are free and immediate, so whenever the app is in front and the face the
/// widget last RENDERED lags the current one, it asks again — once per face (per activation), so a
/// device with no widget on the home screen costs one no-op request per status change.
struct WidgetRenderCatchUp {
    var readRenderedFace: () -> WidgetFace?
    var reload: () -> Void
    /// The last face this process asked for; a face is never asked for twice in a row.
    private(set) var lastRequestedFace: WidgetFace?

    init(readRenderedFace: @escaping () -> WidgetFace?, reload: @escaping () -> Void) {
        self.readRenderedFace = readRenderedFace
        self.reload = reload
    }

    /// Returns true when a reload was requested.
    @discardableResult
    mutating func publish(currentFace: WidgetFace) -> Bool {
        guard readRenderedFace() != currentFace, lastRequestedFace != currentFace else { return false }
        lastRequestedFace = currentFace
        reload()
        return true
    }

    /// Forget the dedupe (the app came to the foreground): a request that was deferred while it was
    /// away is worth repeating now that it is free.
    mutating func resetForActivation() {
        lastRequestedFace = nil
    }

    static func live() -> WidgetRenderCatchUp {
        WidgetRenderCatchUp(
            readRenderedFace: { WidgetSharedState.renderedFace() },
            reload: {
                #if canImport(WidgetKit)
                WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
                #endif
            }
        )
    }
}
