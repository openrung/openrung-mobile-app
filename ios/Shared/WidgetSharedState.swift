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

    static func currentFace() -> WidgetFace {
        face(fromSnapshotData: defaults?.data(forKey: connectionSnapshotKey))
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
/// daily reload budget is small, and the snapshot is rewritten for every log line.
struct WidgetReloadGate {
    var readLastFace: () -> WidgetFace?
    var writeLastFace: (WidgetFace) -> Void
    var reload: () -> Void

    /// Returns true when a reload was requested.
    @discardableResult
    func publish(statusRawValue: String) -> Bool {
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
        reload: {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
            #endif
        }
    )
}
