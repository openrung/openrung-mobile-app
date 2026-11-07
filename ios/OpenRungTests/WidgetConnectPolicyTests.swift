import XCTest

/// Hostless coverage for the widget handoff. These tests do not load NetworkExtension,
/// WidgetKit, or a VPN profile. Xcode is required to run them; the Linux CI run covers the
/// string parity and the same decision table in Jest.
final class WidgetConnectPolicyTests: XCTestCase {
    func testPhaseTreatsMissingProfileAsSetupEvenWhenSnapshotSaysConnected() {
        XCTAssertEqual(
            WidgetConnectPolicy.phase(profileReady: false, status: .connected),
            .setupRequired
        )
        XCTAssertEqual(
            WidgetConnectPolicy.phase(profileReady: true, status: .preparing),
            .connecting
        )
        XCTAssertEqual(WidgetConnectPolicy.phase(profileReady: true, status: .connecting), .connecting)
        XCTAssertEqual(WidgetConnectPolicy.phase(profileReady: true, status: .connected), .connected)
        XCTAssertEqual(WidgetConnectPolicy.phase(profileReady: true, status: .disconnecting), .disconnecting)
        XCTAssertEqual(WidgetConnectPolicy.phase(profileReady: true, status: .failed), .failed)
        XCTAssertEqual(WidgetConnectPolicy.phase(profileReady: true, status: .disconnected), .disconnected)
    }

    func testOnlySetupSkipsTheConnectRequest() {
        XCTAssertFalse(WidgetConnectPolicy.enqueuesConnect(phase: .setupRequired))
        for phase: WidgetDisplayPhase in [.disconnected, .connecting, .connected, .disconnecting, .failed] {
            XCTAssertTrue(WidgetConnectPolicy.enqueuesConnect(phase: phase), phase.rawValue)
        }
    }

    func testShouldStartOnlyWhenTheSavedProfileIsIdle() {
        for status: WidgetSystemStatus in [.disconnected, .invalid] {
            XCTAssertTrue(WidgetConnectPolicy.shouldStart(
                profileReady: true,
                systemStatus: status,
                commandInFlight: false,
                recentCommand: false
            ))
        }
        for status: WidgetSystemStatus in [.connecting, .connected, .reasserting, .disconnecting] {
            XCTAssertFalse(WidgetConnectPolicy.shouldStart(
                profileReady: true,
                systemStatus: status,
                commandInFlight: false,
                recentCommand: false
            ), status.rawValue)
        }
        XCTAssertFalse(WidgetConnectPolicy.shouldStart(
            profileReady: false,
            systemStatus: .disconnected,
            commandInFlight: false,
            recentCommand: false
        ))
        XCTAssertFalse(WidgetConnectPolicy.shouldStart(
            profileReady: true,
            systemStatus: .disconnected,
            commandInFlight: true,
            recentCommand: false
        ))
        XCTAssertFalse(WidgetConnectPolicy.shouldStart(
            profileReady: true,
            systemStatus: .disconnected,
            commandInFlight: false,
            recentCommand: true
        ))
    }

    func testRequestFreshnessWindow() {
        let ttl = WidgetConnectPolicy.requestTTLMillis
        let skew = WidgetConnectPolicy.futureSkewMillis
        XCTAssertEqual(ttl, 90_000)
        XCTAssertEqual(skew, 60_000)
        XCTAssertEqual(WidgetConnectPolicy.duplicateStartSuppressionMillis, 1_500)
        XCTAssertTrue(WidgetConnectPolicy.isFresh(issuedAtMillis: 1_000, nowMillis: 1_000))
        XCTAssertTrue(WidgetConnectPolicy.isFresh(issuedAtMillis: 1_000, nowMillis: 1_000 + ttl))
        XCTAssertFalse(WidgetConnectPolicy.isFresh(issuedAtMillis: 1_000, nowMillis: 1_000 + ttl + 1))
        XCTAssertTrue(WidgetConnectPolicy.isFresh(issuedAtMillis: 10_000, nowMillis: 10_000 - skew))
        XCTAssertFalse(WidgetConnectPolicy.isFresh(issuedAtMillis: 10_000, nowMillis: 10_000 - skew - 1))
    }

    func testURLAllowsOnlyTheTwoHostsWithNoTarget() {
        let accepted: [(String, WidgetConnectURLKind)] = [
            ("openrung://open", .open),
            ("openrung://open/", .open),
            ("OPENRUNG://Open", .open),
            ("openrung://connect-auto", .wake),
            ("openrung://connect-auto/", .wake),
        ]
        for (raw, kind) in accepted {
            XCTAssertEqual(WidgetConnectURL.classify(URL(string: raw)!), kind, raw)
        }
        let rejected = [
            "https://broker.example/connect-auto",
            "openrung://connect-auto?relay=relay-1",
            "openrung://connect-auto?country=JP",
            "openrung://open?x=1",
            "openrung://connect-auto#token",
            "openrung://user:secret@connect-auto",
            "openrung://connect-auto:443",
            "openrung://connect-auto/extra",
            "openrung://connect",
            "openrung://",
            "openrung://open/connect-auto",
        ]
        for raw in rejected {
            XCTAssertNil(WidgetConnectURL.classify(URL(string: raw)!), raw)
        }
        XCTAssertEqual(WidgetConnectURL.classify(WidgetConnectURL.openApp()), .open)
        XCTAssertEqual(WidgetConnectURL.classify(WidgetConnectURL.wakeApp()), .wake)
    }

    func testRequestIsSingleUseAndReplacedByANewerTap() {
        let store = MemoryWidgetStore()
        let first = WidgetConnectRequestStore.enqueue(in: store, nowMillis: 5_000, id: "11111111-1111-1111-1111-111111111111")
        let second = WidgetConnectRequestStore.enqueue(in: store, nowMillis: 5_100, id: "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(first?.id, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(
            WidgetConnectRequestStore.consume(from: store, nowMillis: 5_100)?.id,
            second?.id
        )
        XCTAssertNil(WidgetConnectRequestStore.consume(from: store, nowMillis: 5_100))
    }

    func testStaleWrongAndCorruptRequestsAreDiscarded() {
        let store = MemoryWidgetStore()
        XCTAssertNotNil(WidgetConnectRequestStore.enqueue(
            in: store,
            nowMillis: 1_000,
            id: "33333333-3333-3333-3333-333333333333"
        ))
        XCTAssertNil(WidgetConnectRequestStore.consume(from: store, nowMillis: 1_000 + 90_001))
        XCTAssertNil(store.widgetData(forKey: AppConfig.widgetConnectRequestDefaultsKey))

        let foreign = WidgetConnectRequest(id: "44444444-4444-4444-4444-444444444444", action: "connect-country", issuedAtMillis: 2_000)
        store.setWidgetData(try? JSONEncoder().encode(foreign), forKey: AppConfig.widgetConnectRequestDefaultsKey)
        XCTAssertNil(WidgetConnectRequestStore.consume(from: store, nowMillis: 2_000))

        store.setWidgetData(Data("not-json".utf8), forKey: AppConfig.widgetConnectRequestDefaultsKey)
        XCTAssertNil(WidgetConnectRequestStore.consume(from: store, nowMillis: 2_000))
        XCTAssertNil(store.widgetData(forKey: AppConfig.widgetConnectRequestDefaultsKey))

        XCTAssertNil(WidgetConnectRequestStore.enqueue(in: store, nowMillis: 1, id: "not-a-uuid"))
    }

    func testHandoffRecordsAConnectOnlyAfterTheProfileFlagIsSet() {
        let store = MemoryWidgetStore()
        let connected = ConnectionStateSnapshot(status: .connected, relayLabel: "Tokyo")
        store.setWidgetData(try? JSONEncoder().encode(connected), forKey: AppConfig.connectionStateDefaultsKey)
        XCTAssertFalse(WidgetConnectHandoff.recordWidgetTap(store: store, nowMillis: 10))
        XCTAssertNil(store.widgetData(forKey: AppConfig.widgetConnectRequestDefaultsKey))

        WidgetPreferences.setProfileReady(true, store)
        XCTAssertTrue(WidgetConnectHandoff.recordWidgetTap(store: store, nowMillis: 10))
        let request = WidgetConnectRequestStore.consume(from: store, nowMillis: 10)
        XCTAssertEqual(request?.action, WidgetConnectRequest.autoAction)
    }

    func testViewModelCopyAndRelayDetail() {
        let disconnected = WidgetViewModel.load(
            profileReady: true,
            languageTag: "en",
            systemLocale: "fr-FR",
            snapshot: ConnectionStateSnapshot(status: .disconnected, relayLabel: "should-not-show")
        )
        XCTAssertEqual(disconnected.phase, .disconnected)
        XCTAssertEqual(disconnected.buttonTitle, "CONNECT")
        XCTAssertEqual(disconnected.detailLine, "auto relay")
        XCTAssertTrue(disconnected.enqueuesConnect)
        XCTAssertFalse(disconnected.rightToLeft)

        let connected = WidgetViewModel.load(
            profileReady: true,
            languageTag: "fa",
            systemLocale: "en",
            snapshot: ConnectionStateSnapshot(status: .connected, relayLabel: "Tokyo, Japan", relayName: "Relay 7")
        )
        XCTAssertEqual(connected.statusLine, "متصل")
        XCTAssertEqual(connected.detailLine, "Tokyo, Japan")
        XCTAssertEqual(connected.buttonTitle, "باز کردن")
        XCTAssertTrue(connected.rightToLeft)
        XCTAssertTrue(connected.enqueuesConnect)

        let denied = WidgetViewModel.load(
            profileReady: true,
            languageTag: "en",
            systemLocale: "en",
            snapshot: ConnectionStateSnapshot(status: .failed, lastError: "raw", lastErrorCode: "access_denied")
        )
        XCTAssertEqual(
            denied.detailLine,
            "Access for this device has been disabled, so it cannot connect. Contact OpenRung support."
        )
        XCTAssertEqual(denied.buttonTitle, "CONNECT")

        let setup = WidgetViewModel.load(
            profileReady: false,
            languageTag: "",
            systemLocale: "en_US",
            snapshot: ConnectionStateSnapshot(status: .connected)
        )
        XCTAssertEqual(setup.phase, .setupRequired)
        XCTAssertEqual(setup.buttonTitle, "Open")
        XCTAssertFalse(setup.enqueuesConnect)
        XCTAssertEqual(WidgetViewModel.placeholder.phase, .disconnected)
    }

    func testLanguageResolutionMatchesTheAppRules() {
        XCTAssertEqual(WidgetStrings.resolve(tag: "", systemLocale: "fa-IR"), "fa")
        XCTAssertEqual(WidgetStrings.resolve(tag: "vi-VN", systemLocale: "en"), "vi")
        XCTAssertEqual(WidgetStrings.resolve(tag: "zh-HK", systemLocale: "en"), "zh-TW")
        XCTAssertEqual(WidgetStrings.resolve(tag: "zh-Hans", systemLocale: "en"), "zh-CN")
        XCTAssertEqual(WidgetStrings.resolve(tag: "zh_TW", systemLocale: "en"), "zh-TW")
        XCTAssertEqual(WidgetStrings.resolve(tag: "pt-BR", systemLocale: "en"), "en")
        XCTAssertEqual(WidgetStrings.resolve(tag: "en", systemLocale: "fa-IR"), "en")
        XCTAssertEqual(WidgetStrings.sanitizedLanguageTag("zh-CN"), "zh-CN")
        XCTAssertEqual(WidgetStrings.sanitizedLanguageTag(""), "")
        XCTAssertEqual(WidgetStrings.sanitizedLanguageTag("zh CN"), "")
        XCTAssertEqual(WidgetStrings.sanitizedLanguageTag("../en"), "")
        XCTAssertEqual(WidgetStrings.sanitizedLanguageTag(String(repeating: "a", count: 33)), "")
        XCTAssertEqual(WidgetStrings.systemLanguageTag("en_US"), "en-US")
    }

    func testErrorLineIsTruncated() {
        let error = String(repeating: "e", count: 120)
        let model = WidgetViewModel.load(
            profileReady: true,
            languageTag: "en",
            systemLocale: "en",
            snapshot: ConnectionStateSnapshot(status: .failed, lastError: error)
        )
        XCTAssertEqual(model.detailLine?.count, 80)
        XCTAssertTrue(model.detailLine?.hasSuffix("…") == true)
    }
}

private final class MemoryWidgetStore: WidgetKeyValueStore {
    private var data: [String: Data] = [:]
    private var bools: [String: Bool] = [:]
    private var strings: [String: String] = [:]

    func widgetData(forKey key: String) -> Data? { data[key] }
    func setWidgetData(_ value: Data?, forKey key: String) {
        if let value {
            data[key] = value
        } else {
            data.removeValue(forKey: key)
        }
    }
    func widgetBool(forKey key: String) -> Bool { bools[key] ?? false }
    func setWidgetBool(_ value: Bool, forKey key: String) { bools[key] = value }
    func widgetString(forKey key: String) -> String? { strings[key] }
    func setWidgetString(_ value: String?, forKey key: String) {
        if let value {
            strings[key] = value
        } else {
            strings.removeValue(forKey: key)
        }
    }
}
