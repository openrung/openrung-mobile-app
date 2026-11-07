import Foundation

/// Wake-up URLs for the widget. They carry no relay id, country, broker, or credential.
/// A URL alone never starts the tunnel: the host app also requires a fresh app-group request
/// that only this app's widget can write. Anything other than the two hosts is ignored.
enum WidgetConnectURLKind: String, Equatable, Sendable {
    /// Open the app. Does not by itself authorize a connect.
    case open
    /// Same foreground wake, named so logs can tell a connect tap from a status tap.
    /// Authorization is still the app-group request, not this host.
    case wake
}

enum WidgetConnectURL {
    static func openApp() -> URL {
        url(host: "open")
    }

    static func wakeApp() -> URL {
        url(host: "connect-auto")
    }

    static func classify(_ url: URL) -> WidgetConnectURLKind? {
        guard url.scheme?.lowercased() == AppConfig.widgetURLScheme else { return nil }
        guard url.user == nil, url.password == nil else { return nil }
        guard url.port == nil else { return nil }
        guard url.query == nil, url.fragment == nil else { return nil }
        let path = url.path
        guard path.isEmpty || path == "/" else { return nil }
        switch url.host?.lowercased() {
        case "open":
            return .open
        case "connect-auto":
            return .wake
        default:
            return nil
        }
    }

    private static func url(host: String) -> URL {
        var components = URLComponents()
        components.scheme = AppConfig.widgetURLScheme
        components.host = host
        guard let url = components.url else {
            preconditionFailure("widget URL \(host) must be constructible")
        }
        return url
    }
}
