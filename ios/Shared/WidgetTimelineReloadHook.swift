import Foundation

/// Process-local hook the app and the packet tunnel install so a status write can ask WidgetKit
/// to reload. Shared code stays free of WidgetKit; the default is a no-op for tests and for any
/// process that never installs a reloader. WidgetKit still decides when a reload actually runs.
enum WidgetTimelineReloadHook {
    private static let lock = NSLock()
    private static var reloadImpl: @Sendable () -> Void = {}

    static func setReload(_ reload: @escaping @Sendable () -> Void) {
        lock.lock()
        reloadImpl = reload
        lock.unlock()
    }

    static func reload() {
        lock.lock()
        let reload = reloadImpl
        lock.unlock()
        reload()
    }
}
