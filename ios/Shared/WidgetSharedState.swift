import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The home-screen widget's read-only view of the tunnel, and the app-group keys the app and the
/// PacketTunnel extension use to feed it (contract §2 / §7).
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
    /// App-written (`WidgetStaleTunnelMarker`): true when the OS reported the tunnel down while
    /// the snapshot still claimed it live (the extension was killed). Removed by the tunnel on
    /// its next snapshot write, so a real tunnel always supersedes it.
    static let systemTunnelDownKey = "widget_system_tunnel_down"
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

    static func currentLanguageTag() -> String {
        defaults?.string(forKey: languageTagKey) ?? ""
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
}

/// Asks WidgetKit to reload only when the rendered face changed since the last request: WidgetKit's
/// daily reload budget is small, and the snapshot is rewritten for every log line. Runs in the
/// tunnel extension on every snapshot flush, and every flush retires the app's stale-tunnel marker:
/// a fresh tunnel write is the truth, whatever the app concluded earlier.
struct WidgetReloadGate {
    var readLastFace: () -> WidgetFace?
    var writeLastFace: (WidgetFace) -> Void
    var clearStaleTunnelMarker: () -> Void
    var reload: () -> Void

    /// Returns true when a reload was requested.
    @discardableResult
    func publish(statusRawValue: String) -> Bool {
        clearStaleTunnelMarker()
        let face = WidgetFace(statusRawValue: statusRawValue)
        guard readLastFace() != face else { return false }
        writeLastFace(face)
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
        },
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
