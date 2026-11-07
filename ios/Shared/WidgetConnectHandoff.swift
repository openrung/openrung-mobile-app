import Foundation

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
/// run an intent, and as the plain "open the app" tap target on every version.
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

    /// Submits one request when any URL handed to the scene is the connect URL; every other URL
    /// under the scheme merely opened the app. Returns whether a request was accepted.
    @discardableResult
    static func handle<URLs: Sequence>(
        _ urls: URLs,
        mailbox: WidgetConnectMailbox = .shared,
        now: Date = Date()
    ) -> Bool where URLs.Element == URL {
        guard urls.contains(where: isConnectRequest) else { return false }
        return mailbox.submit(WidgetConnectRequest(source: .url, issuedAt: now))
    }
}
