import Foundation

/// One in-flight "connect to the automatic relay" request. The only stored fields are an id,
/// the fixed action, and a timestamp. Relay choice stays inside the packet tunnel.
struct WidgetConnectRequest: Codable, Equatable, Sendable {
    static let autoAction = "connect-auto"

    var id: String
    var action: String
    var issuedAtMillis: Int64
}

/// Minimal app-group surface. Method names stay off `UserDefaults`' own selectors so the
/// conformance cannot recurse. Tests use an in-memory box.
protocol WidgetKeyValueStore: AnyObject {
    func widgetData(forKey key: String) -> Data?
    func setWidgetData(_ data: Data?, forKey key: String)
    func widgetBool(forKey key: String) -> Bool
    func setWidgetBool(_ value: Bool, forKey key: String)
    func widgetString(forKey key: String) -> String?
    func setWidgetString(_ value: String?, forKey key: String)
}

extension UserDefaults: WidgetKeyValueStore {
    func widgetData(forKey key: String) -> Data? { data(forKey: key) }

    func setWidgetData(_ data: Data?, forKey key: String) {
        if let data {
            set(data, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }

    func widgetBool(forKey key: String) -> Bool { bool(forKey: key) }

    func setWidgetBool(_ value: Bool, forKey key: String) {
        set(value, forKey: key)
    }

    func widgetString(forKey key: String) -> String? { string(forKey: key) }

    func setWidgetString(_ value: String?, forKey key: String) {
        if let value {
            set(value, forKey: key)
        } else {
            removeObject(forKey: key)
        }
    }
}

enum WidgetAppGroup {
    static var store: WidgetKeyValueStore? {
        UserDefaults(suiteName: AppConfig.appGroupIdentifier)
    }
}

enum WidgetPreferences {
    static func isProfileReady(_ store: WidgetKeyValueStore) -> Bool {
        store.widgetBool(forKey: AppConfig.widgetVpnProfileReadyDefaultsKey)
    }

    static func setProfileReady(_ ready: Bool, _ store: WidgetKeyValueStore) {
        store.setWidgetBool(ready, forKey: AppConfig.widgetVpnProfileReadyDefaultsKey)
    }

    static func languageTag(_ store: WidgetKeyValueStore) -> String {
        WidgetStrings.sanitizedLanguageTag(store.widgetString(forKey: AppConfig.widgetLanguageTagDefaultsKey) ?? "")
    }

    static func setLanguageTag(_ tag: String, _ store: WidgetKeyValueStore) {
        store.setWidgetString(WidgetStrings.sanitizedLanguageTag(tag), forKey: AppConfig.widgetLanguageTagDefaultsKey)
    }
}

enum WidgetConnectRequestStore {
    static func enqueue(
        in store: WidgetKeyValueStore,
        nowMillis: Int64,
        id: String = UUID().uuidString
    ) -> WidgetConnectRequest? {
        let request = WidgetConnectRequest(
            id: id,
            action: WidgetConnectRequest.autoAction,
            issuedAtMillis: nowMillis
        )
        guard UUID(uuidString: id) != nil, let data = try? JSONEncoder().encode(request) else {
            return nil
        }
        store.setWidgetData(data, forKey: AppConfig.widgetConnectRequestDefaultsKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(AppConfig.widgetConnectDarwinNotificationName as CFString),
            nil,
            nil,
            true
        )
        return request
    }

    /// Removes the stored request. Returns it only when it is the auto-connect action, has a
    /// UUID id, and is inside the freshness window. A stale or foreign payload is discarded.
    static func consume(from store: WidgetKeyValueStore, nowMillis: Int64) -> WidgetConnectRequest? {
        let data = store.widgetData(forKey: AppConfig.widgetConnectRequestDefaultsKey)
        store.setWidgetData(nil, forKey: AppConfig.widgetConnectRequestDefaultsKey)
        guard
            let data,
            let request = try? JSONDecoder().decode(WidgetConnectRequest.self, from: data),
            request.action == WidgetConnectRequest.autoAction,
            UUID(uuidString: request.id) != nil,
            WidgetConnectPolicy.isFresh(issuedAtMillis: request.issuedAtMillis, nowMillis: nowMillis)
        else {
            return nil
        }
        return request
    }
}

enum WidgetConnectHandoff {
    /// Records a connect request only when the widget is past VPN setup. Returns whether a
    /// request was stored. The caller still opens the app either way.
    @discardableResult
    static func recordWidgetTap(store: WidgetKeyValueStore, nowMillis: Int64) -> Bool {
        let model = WidgetViewModel.load(
            profileReady: WidgetPreferences.isProfileReady(store),
            languageTag: WidgetPreferences.languageTag(store),
            systemLocale: WidgetStrings.systemLanguageTag(),
            snapshot: WidgetConnectionReader.snapshot(from: store)
        )
        guard model.enqueuesConnect else { return false }
        return WidgetConnectRequestStore.enqueue(in: store, nowMillis: nowMillis) != nil
    }
}

enum WidgetConnectionReader {
    static func snapshot(from store: WidgetKeyValueStore) -> ConnectionStateSnapshot {
        guard
            let data = store.widgetData(forKey: AppConfig.connectionStateDefaultsKey),
            let snapshot = try? JSONDecoder().decode(ConnectionStateSnapshot.self, from: data)
        else {
            return ConnectionStateSnapshot()
        }
        return snapshot
    }
}
