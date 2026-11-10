import Foundation
import notify
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The home-screen widget's view of the tunnel, and the app-group keys the app and the PacketTunnel
/// extension use to feed it (contract §2 / §7). The widget reads everything here and writes two
/// keys of its own (`widget_rendered_face`, `widget_disconnect_request`).
///
/// The PacketTunnel extension stays the sole writer of the `connection_state` snapshot; the widget
/// decodes just what it shows (`status`, the connected relay's display name and that relay's
/// country) as raw strings, so this file needs nothing else from Shared/. Everything the app and
/// the widget publish lives under their own `widget_*` keys, so neither can clobber the snapshot.
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
    /// Widget-written: the face of the last timeline it built. A reload
    /// request is not a render — WidgetKit budgets and defers requests made while the app is not
    /// in the foreground — so the app re-requests while this lags (`WidgetRenderCatchUp`).
    static let renderedFaceKey = "widget_rendered_face"
    /// Written by `WidgetReloadGate` with the face: the connected relay it last asked WidgetKit to
    /// show (`WidgetRelay.signature`), absent on every other face.
    static let lastPublishedRelayKey = "widget_last_relay"
    /// Widget-written (`WidgetDisconnectRequest`): when its Disconnect control was tapped (seconds
    /// since 1970). The tunnel acts on a fresh one and removes it.
    static let disconnectRequestKey = "widget_disconnect_request"
    /// App-written (`WidgetBackgroundConnect`): true once the app has a saved VPN profile, which is
    /// when the widget's Connect can run without opening the app.
    static let backgroundConnectKey = "widget_background_connect"
    /// Darwin notification telling the tunnel to look at `disconnectRequestKey`. It carries no
    /// authority of its own: any process can post it, only an app-group member can write the key.
    static let disconnectNotificationName = "com.openrung.app.widget-disconnect"
    /// WidgetKit `kind` of the single widget; reload requests target exactly this.
    static let widgetKind = "OpenRungConnect"

    // One suite instance per process (see SharedConnectionState for why not a computed property).
    static let defaults: UserDefaults? = UserDefaults(suiteName: appGroupIdentifier)

    /// Decodes what the widget shows out of a persisted snapshot. Anything missing or undecodable
    /// reads as disconnected, the face from which a connect is offered — never a stale "connected".
    static func display(fromSnapshotData data: Data?) -> WidgetDisplay {
        guard let data, let slice = try? JSONDecoder().decode(SnapshotSlice.self, from: data) else {
            return WidgetDisplay(face: .disconnected)
        }
        let face = WidgetFace(statusRawValue: slice.status ?? "")
        guard face == .connected else { return WidgetDisplay(face: face) }
        return WidgetDisplay(face: face, relay: WidgetRelay(name: slice.relayName, recents: slice.recents))
    }

    static func face(fromSnapshotData data: Data?) -> WidgetFace {
        display(fromSnapshotData: data).face
    }

    /// The face from a snapshot, overridden to disconnected while the app's stale-tunnel marker
    /// says the OS has no such tunnel.
    static func face(fromSnapshotData data: Data?, systemTunnelDown: Bool) -> WidgetFace {
        systemTunnelDown ? .disconnected : face(fromSnapshotData: data)
    }

    /// What the widget shows for a decoded snapshot once the keys around it are applied: the
    /// app's stale-tunnel marker wins, then a Disconnect tap the tunnel has not yet answered
    /// reads as disconnecting. `since` is when the tunnel entered the face (the gate's record,
    /// when it is for this face) or when the pending disconnect was requested.
    static func resolve(
        snapshot: WidgetDisplay,
        systemTunnelDown: Bool,
        disconnectRequestedAt: Double?,
        lastFace: WidgetFace?,
        lastFaceAt: Double?,
        now: Date
    ) -> WidgetDisplay {
        if systemTunnelDown { return WidgetDisplay(face: .disconnected) }
        if snapshot.face == .connected, let disconnectRequestedAt,
           WidgetDisconnectRequest.isFresh(issuedAt: disconnectRequestedAt, now: now) {
            let requested = Date(timeIntervalSince1970: disconnectRequestedAt)
            return WidgetDisplay(
                face: .disconnecting,
                since: requested,
                expires: requested.addingTimeInterval(WidgetDisconnectRequest.maxAge)
            )
        }
        var display = snapshot
        if lastFace == snapshot.face, let lastFaceAt {
            display.since = Date(timeIntervalSince1970: lastFaceAt)
        }
        return display
    }

    static func currentDisplay(now: Date = Date()) -> WidgetDisplay {
        resolve(
            snapshot: display(fromSnapshotData: defaults?.data(forKey: connectionSnapshotKey)),
            systemTunnelDown: defaults?.bool(forKey: systemTunnelDownKey) ?? false,
            disconnectRequestedAt: defaults?.object(forKey: disconnectRequestKey) as? Double,
            lastFace: defaults?.string(forKey: lastPublishedFaceKey).flatMap(WidgetFace.init(rawValue:)),
            lastFaceAt: defaults?.object(forKey: lastPublishedFaceDateKey) as? Double,
            now: now
        )
    }

    static func currentFace() -> WidgetFace {
        currentDisplay().face
    }

    /// The displays a timeline built at `now` should carry: the current one and, when that one
    /// expires by itself, what replaces it. WidgetKit switches entries on time by itself, whereas
    /// a reload asked for through the timeline's policy may be deferred.
    static func timelineDisplays(now: Date, display: (Date) -> WidgetDisplay) -> [(date: Date, display: WidgetDisplay)] {
        let first = display(now)
        guard let expires = first.expires, expires >= now else { return [(now, first)] }
        // Just past the limit, where the request no longer reads as fresh.
        let next = expires.addingTimeInterval(1)
        return [(now, first), (next, display(next))]
    }

    /// Whether the snapshot itself (ignoring a pending disconnect) still has a tunnel to stop.
    static func tunnelIsLive() -> Bool {
        let face = face(
            fromSnapshotData: defaults?.data(forKey: connectionSnapshotKey),
            systemTunnelDown: defaults?.bool(forKey: systemTunnelDownKey) ?? false
        )
        return face == .connected || face == .disconnecting
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

    /// The slice of `ConnectionStateSnapshot` the widget reads. Each field is optional and decoded
    /// leniently: a malformed relay or recents entry costs the relay line, never the status.
    private struct SnapshotSlice: Decodable {
        let status: String?
        let relayName: String?
        let recents: [WidgetRelay.Recent]

        enum CodingKeys: String, CodingKey {
            case status, relayName, recentRegions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            relayName = try? container.decodeIfPresent(String.self, forKey: .relayName)
            recents = (try? container.decodeIfPresent([WidgetRelay.Recent].self, forKey: .recentRegions)) ?? []
        }
    }
}

/// Everything one render of the widget shows about the tunnel.
struct WidgetDisplay: Equatable {
    var face: WidgetFace
    /// The connected relay; nil on every other face.
    var relay: WidgetRelay?
    /// When this face began, where known: the connected timer's origin, and what paces the
    /// refresh of a transitional face.
    var since: Date?
    /// When this stops being what to show although nothing else changes: the moment an unanswered
    /// Disconnect tap goes stale. Nil for everything the tunnel itself reports.
    var expires: Date?

    init(face: WidgetFace, relay: WidgetRelay? = nil, since: Date? = nil, expires: Date? = nil) {
        self.face = face
        self.relay = relay
        self.since = since
        self.expires = expires
    }
}

/// The connected relay as the widget shows it: its display name (already sanitized by the tunnel)
/// and, when the snapshot's most recent region is this relay, that region's country.
struct WidgetRelay: Equatable {
    let name: String
    /// ISO 3166-1 alpha-2, uppercased.
    let countryCode: String?

    struct Recent: Decodable, Equatable {
        let countryCode: String?
        let relayName: String?

        enum CodingKeys: String, CodingKey {
            case countryCode, relayName
        }

        init(countryCode: String?, relayName: String?) {
            self.countryCode = countryCode
            self.relayName = relayName
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            countryCode = try? container.decodeIfPresent(String.self, forKey: .countryCode)
            relayName = try? container.decodeIfPresent(String.self, forKey: .relayName)
        }
    }

    init?(name: String?, recents: [Recent] = []) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        self.name = name
        // The tunnel records the connected relay at the head of the recents; an older entry is
        // some other session's and says nothing about this one.
        let code = recents.first.flatMap { $0.relayName == name ? $0.countryCode : nil }
        countryCode = code.flatMap(Self.normalizedCountryCode)
    }

    /// The country's flag emoji (a regional-indicator pair), nil without a country.
    var flag: String? {
        guard let countryCode else { return nil }
        var flag = String.UnicodeScalarView()
        for scalar in countryCode.unicodeScalars {
            guard let indicator = Unicode.Scalar(0x1F1E6 + scalar.value - 65) else { return nil }
            flag.append(indicator)
        }
        return String(flag)
    }

    /// Identity for the reload gate: a change means the connected face shows something new.
    var signature: String {
        "\(name)|\(countryCode ?? "")"
    }

    private static func normalizedCountryCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.unicodeScalars.count == 2,
              code.unicodeScalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 })
        else { return nil }
        return code
    }
}

/// The widget's Disconnect control (iOS 17+). The widget extension cannot reach a tunnel manager
/// and must not launch the app for this, so it leaves a timestamp under its own app-group key and
/// pokes the tunnel with a Darwin notification; the tunnel, which is necessarily running, ends
/// itself. The request names nothing (there is only one tunnel to stop) and goes stale quickly,
/// so one that found no tunnel can never stop a later one.
enum WidgetDisconnectRequest {
    /// A request older than this is ignored by the tunnel and no longer shown as pending.
    static let maxAge: TimeInterval = 15
    /// How long the widget's intent waits for the tunnel to settle before its timeline is rebuilt.
    static let settleWait: TimeInterval = 5

    static func isFresh(issuedAt: Double?, now: Date) -> Bool {
        guard let issuedAt else { return false }
        let age = now.timeIntervalSince1970 - issuedAt
        return age >= 0 && age <= maxAge
    }

    /// Widget side: record the tap, then tell the tunnel to look.
    static func submit(now: Date = Date()) {
        guard let defaults = WidgetSharedState.defaults else { return }
        defaults.set(now.timeIntervalSince1970, forKey: WidgetSharedState.disconnectRequestKey)
        // Push the write out before the tunnel is told to read it.
        defaults.synchronize()
        notify_post(WidgetSharedState.disconnectNotificationName)
    }

    /// Tunnel side: true exactly once for a fresh request. Whatever was stored is removed.
    static func consume(now: Date = Date()) -> Bool {
        guard let defaults = WidgetSharedState.defaults,
              let issuedAt = defaults.object(forKey: WidgetSharedState.disconnectRequestKey) as? Double
        else { return false }
        defaults.removeObject(forKey: WidgetSharedState.disconnectRequestKey)
        return isFresh(issuedAt: issuedAt, now: now)
    }

    /// Tunnel side, at start: a request left over from before this tunnel is not for it.
    static func clear() {
        WidgetSharedState.defaults?.removeObject(forKey: WidgetSharedState.disconnectRequestKey)
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

/// Asks WidgetKit to reload only when what the widget shows changed since the last request (and the
/// widget has not already rendered it): WidgetKit's daily reload budget is small, and the snapshot
/// is rewritten for every log line. "What it shows" is the face, plus the relay on the connected
/// face. Runs in the tunnel extension on every snapshot flush, and every flush retires the app's
/// stale-tunnel marker: a fresh tunnel write is the truth, whatever the app concluded earlier. A
/// request made while the app is not in the foreground is budgeted and may be deferred; the
/// widget's own refresh of a transitional face (`WidgetSelfRefresh`) and `WidgetRenderCatchUp`
/// (app, the next time it is in front) cover that.
struct WidgetReloadGate {
    var readLastFace: () -> WidgetFace?
    var writeLastFace: (WidgetFace) -> Void
    var readLastRelay: () -> String? = { nil }
    var writeLastRelay: (String?) -> Void = { _ in }
    var readRenderedFace: () -> WidgetFace?
    var clearStaleTunnelMarker: () -> Void
    var reload: () -> Void

    /// Returns true when a reload was requested.
    @discardableResult
    func publish(_ display: WidgetDisplay) -> Bool {
        clearStaleTunnelMarker()
        let face = display.face
        let relay = face == .connected ? display.relay?.signature : nil
        let faceChanged = readLastFace() != face
        let relayChanged = readLastRelay() != relay
        if faceChanged { writeLastFace(face) }
        if relayChanged { writeLastRelay(relay) }
        if faceChanged {
            // The widget may be there already: the app's catch-up (e.g. after a launch), or its
            // own reading of a Disconnect tap.
            guard readRenderedFace() != face else { return false }
        } else {
            // Same face: only a new relay on the connected face is worth a reload.
            guard relayChanged, face == .connected else { return false }
        }
        reload()
        return true
    }

    @discardableResult
    func publish(statusRawValue: String) -> Bool {
        publish(WidgetDisplay(face: WidgetFace(statusRawValue: statusRawValue)))
    }

    /// The tunnel's entry point: the snapshot it just persisted, read the way the widget will.
    @discardableResult
    func publish(snapshotData: Data) -> Bool {
        publish(WidgetSharedState.display(fromSnapshotData: snapshotData))
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
        readLastRelay: { WidgetSharedState.defaults?.string(forKey: WidgetSharedState.lastPublishedRelayKey) },
        writeLastRelay: { relay in
            if let relay {
                WidgetSharedState.defaults?.set(relay, forKey: WidgetSharedState.lastPublishedRelayKey)
            } else {
                WidgetSharedState.defaults?.removeObject(forKey: WidgetSharedState.lastPublishedRelayKey)
            }
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
