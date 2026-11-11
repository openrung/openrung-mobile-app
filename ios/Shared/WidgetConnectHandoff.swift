import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

/// One "connect" request from the home-screen widget on its way to the app's existing connect path.
/// It carries no target on purpose: the widget cannot name a relay, country, broker or credential,
/// so connectcore chooses the relay exactly as a Connect tap in the app does.
struct WidgetConnectRequest: Equatable {
    enum Source: String {
        /// `WidgetConnectIntent.perform()`, run by the system inside the app process (iOS 17+).
        case intent
        /// The `openrung://connect` URL the iOS 16 widget opens the app with.
        case url
    }

    let source: Source
    let issuedAt: Date
}

/// App-process mailbox between the widget's two entry points and the RN bridge that acts on them.
/// Holds at most one request, collapses repeat deliveries of one tap, and discards a request nobody
/// collected in time: a cold launch that never reached JavaScript must not connect minutes later.
final class WidgetConnectMailbox {
    static let shared = WidgetConnectMailbox()

    /// A request older than this when collected is dropped.
    static let maxAge: TimeInterval = 30
    /// A tap this soon after a collected one is the same tap (double tap, duplicate delivery).
    static let collapseWindow: TimeInterval = 3

    private let lock = NSLock()
    private var pending: WidgetConnectRequest?
    private var lastCollectedAt: Date?
    /// Invoked (outside the lock) after a request was accepted so a consumer can collect it promptly.
    var onSubmit: (() -> Void)?

    /// Returns false when the request was collapsed into one already pending or just collected.
    @discardableResult
    func submit(_ request: WidgetConnectRequest) -> Bool {
        lock.lock()
        let accepted: Bool
        if let pending, request.issuedAt.timeIntervalSince(pending.issuedAt) <= Self.maxAge {
            // Same tap, or a retap while the first is still fresh and waiting for JavaScript.
            accepted = false
        } else if let lastCollectedAt,
                  request.issuedAt.timeIntervalSince(lastCollectedAt) < Self.collapseWindow {
            accepted = false
        } else {
            pending = request
            accepted = true
        }
        lock.unlock()
        if accepted {
            onSubmit?()
        }
        return accepted
    }

    /// Hands over the pending request if it is still fresh; a stale one is dropped either way.
    func collect(now: Date = Date()) -> WidgetConnectRequest? {
        lock.lock()
        defer { lock.unlock() }
        guard let request = pending else { return nil }
        pending = nil
        guard now.timeIntervalSince(request.issuedAt) <= Self.maxAge else { return nil }
        lastCollectedAt = now
        return request
    }
}

/// The `openrung:` URL scheme (contract §2). The widget uses it on iOS 16, where a widget cannot
/// run an intent, and as the plain "open the app" tap target on every version. The connect URL
/// ACTS only on iOS 16: from iOS 17 the widget goes through the intent, so honouring the URL there
/// would let any app or web link foreground OpenRung and start a tunnel.
enum WidgetConnectURL {
    static let scheme = "openrung"
    static let connectHost = "connect"
    static let connect = URL(string: "openrung://connect")!
    /// Opens the app without acting: the tap target wherever starting a tunnel must not happen.
    static let open = URL(string: "openrung://open")!

    /// Exactly `openrung://connect` — scheme and host compared case-insensitively, and nothing else:
    /// no path, query, fragment, user, password or port, so a URL can never smuggle a target.
    static func isConnectRequest(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.scheme?.lowercased() == scheme
            && components.host?.lowercased() == connectHost
            && components.path.isEmpty
            && components.query == nil
            && components.fragment == nil
            && components.user == nil
            && components.password == nil
            && components.port == nil
    }

    /// Whether this OS version takes connect requests from the URL at all (iOS 16 only).
    static var acceptsURLHandoff: Bool {
        if #available(iOS 17.0, *) {
            return false
        }
        return true
    }

    /// Submits one request when the handoff is enabled and any URL handed to the scene is the
    /// connect URL; every other URL under the scheme merely opened the app. Returns whether a
    /// request was accepted.
    @discardableResult
    static func handle<URLs: Sequence>(
        _ urls: URLs,
        mailbox: WidgetConnectMailbox = .shared,
        now: Date = Date(),
        enabled: Bool = acceptsURLHandoff
    ) -> Bool where URLs.Element == URL {
        guard enabled, urls.contains(where: isConnectRequest) else { return false }
        return mailbox.submit(WidgetConnectRequest(source: .url, issuedAt: now))
    }
}

/// The widget's Connect without opening the app (iOS 17+). The system runs
/// `WidgetBackgroundConnectIntent` inside the app's process, launching the app in the background
/// when it is not running; no JavaScript may exist there, so the app installs a native `start` at
/// launch. That can only work once a VPN profile is saved (saving the first one brings up the OS
/// consent dialog, which needs the app in front), so the app says so under its own app-group key
/// and the widget offers this intent only then, the app-opening `WidgetConnectIntent` otherwise.
/// A start that turns out to be unavailable withdraws the key: the next tap opens the app.
struct WidgetBackgroundConnect {
    enum Outcome: Equatable {
        /// The tunnel was asked to start.
        case started
        /// Nothing to start: a tunnel is up or in motion (`WidgetConnectPolicy`).
        case ignored
        /// No saved profile, or it would not start; only the app, in front, can sort that out.
        case unavailable
    }

    /// Installed by the app at launch (`AppDelegate`). Nil in the widget extension, which cannot
    /// reach a tunnel manager and where the intent is not expected to run.
    static var start: (() async -> Outcome)?
    /// How long the intent waits for the tunnel's first snapshot.
    static let settleWait: TimeInterval = 3
    /// How long it waits, from the start, for a tunnel that did answer to finish connecting. Kept
    /// well inside the time the system allows an intent.
    static let resultWait: TimeInterval = 20

    var readAvailable: () -> Bool
    var writeAvailable: (Bool) -> Void
    var reload: () -> Void

    /// Widget side: which Connect intent to put behind the button.
    var isAvailable: Bool { readAvailable() }

    /// App side, with the app in front: returns true when the value changed (and the widget was
    /// asked to rebuild so its button carries the right intent).
    @discardableResult
    func publish(available: Bool) -> Bool {
        guard readAvailable() != available else { return false }
        writeAvailable(available)
        reload()
        return true
    }

    /// The intent's body. WidgetKit holds the widget's reloads while the intent runs and rebuilds
    /// the timeline once it is over, so nothing here asks for a reload: a withdrawn key is picked
    /// up by that rebuild. That rebuild is also the one reload the widget is sure to get: with the
    /// app in the background every later request, the tunnel's and the widget's own, may be
    /// deferred. So after a start the intent stays open until the connect has an outcome
    /// (`Self.wait`), and the rebuild lands on "connected" or "failed", not on "connecting".
    @discardableResult
    func run(
        start: (() async -> Outcome)? = WidgetBackgroundConnect.start,
        face: () -> WidgetFace = { WidgetSharedState.currentFace() },
        now: () -> Date = Date.init,
        pause: () async -> Void = { _ = try? await Task.sleep(nanoseconds: 150_000_000) }
    ) async -> Outcome {
        let outcome = await start?() ?? .unavailable
        switch outcome {
        case .unavailable:
            writeAvailable(false)
        case .ignored:
            break
        case .started:
            let started = now()
            var answered = false
            while true {
                let wait = Self.wait(face: face(), answered: answered, elapsed: now().timeIntervalSince(started))
                guard wait != .done else { break }
                answered = wait == .forResult
                await pause()
            }
        }
        return outcome
    }

    enum Wait: Equatable {
        /// The tunnel has not written a snapshot for this start yet.
        case forAnswer
        /// It is connecting.
        case forResult
        case done
    }

    /// Whether a started connect is still worth waiting for. `answered` is whether the tunnel has
    /// been seen connecting since the start: until then a settled face is the one from before the
    /// tap. The wait ends on the connect's outcome, or when its time is up (`settleWait` for a
    /// tunnel that never answered, `resultWait` overall), leaving the rest to the widget's own
    /// refresh of a transitional face.
    static func wait(face: WidgetFace, answered: Bool, elapsed: TimeInterval) -> Wait {
        if face == .connecting {
            return elapsed < resultWait ? .forResult : .done
        }
        guard !answered, face.offersConnect, elapsed < settleWait else { return .done }
        return .forAnswer
    }

    static let shared = WidgetBackgroundConnect(
        readAvailable: { WidgetSharedState.defaults?.bool(forKey: WidgetSharedState.backgroundConnectKey) ?? false },
        writeAvailable: { WidgetSharedState.defaults?.set($0, forKey: WidgetSharedState.backgroundConnectKey) },
        reload: {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadTimelines(ofKind: WidgetSharedState.widgetKind)
            #endif
        }
    )
}
