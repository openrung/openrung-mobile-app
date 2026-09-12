import Foundation
import NetworkExtension
import XCTest

/// Opt-in, hosted tests on a signed physical iPhone. Uses the user's existing
/// OpenRung VPN profile with automatic relay selection, then restores its
/// saved configuration/enabled setting with the tunnel stopped. Simulator tests cannot
/// substitute for this path.
final class PacketTunnelDeviceTests: XCTestCase {
    func testRealProviderStopDuringStartReconnectAndMemory() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a signed physical iPhone")
        #else
        let memoryBudget: Double?
        if let raw = ProcessInfo.processInfo.environment["OPENRUNG_IOS_MEMORY_BUDGET_MIB"] {
            let value = try XCTUnwrap(Double(raw), "Memory budget must be a number in MiB")
            guard value.isFinite && value > 0 else {
                XCTFail("Memory budget must be finite and positive")
                return
            }
            memoryBudget = value
        } else { memoryBudget = nil }
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let manager = try XCTUnwrap(managers.first { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == "com.openrung.app.PacketTunnel" }, "Prepare the OpenRung VPN profile once before running device tests")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "group.com.openrung.app"))
        let wasEnabled = manager.isEnabled
        let savedProtocol = try XCTUnwrap(manager.protocolConfiguration?.copy() as? NEVPNProtocol)
        do {
            let testProtocol = try XCTUnwrap(savedProtocol.copy() as? NETunnelProviderProtocol)
            testProtocol.providerConfiguration?.removeValue(forKey: "target_relay_id")
            testProtocol.providerConfiguration?.removeValue(forKey: "target_country")
            manager.protocolConfiguration = testProtocol
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            try await exercise(manager: manager, defaults: defaults, memoryBudget: memoryBudget)
        } catch {
            try await restore(manager: manager, enabled: wasEnabled, savedProtocol: savedProtocol)
            throw error
        }
        try await restore(manager: manager, enabled: wasEnabled, savedProtocol: savedProtocol)
        #endif
    }

    private func restore(manager: NETunnelProviderManager, enabled: Bool, savedProtocol: NEVPNProtocol) async throws {
        manager.connection.stopVPNTunnel()
        try await waitFor("cleanup disconnect") { [.disconnected, .invalid].contains(manager.connection.status) }
        try await manager.loadFromPreferences()
        manager.protocolConfiguration = savedProtocol
        manager.isEnabled = enabled
        try await manager.saveToPreferences()
    }

    private func exercise(manager: NETunnelProviderManager, defaults: UserDefaults, memoryBudget: Double?) async throws {
        let installID = try XCTUnwrap(defaults.string(forKey: "client_id"), "Existing install identity is required for the upgrade check")
        manager.connection.stopVPNTunnel()
        try await waitFor("initial disconnect") { manager.connection.status == .disconnected || manager.connection.status == .invalid }
        defer { manager.connection.stopVPNTunnel() }

        try manager.connection.startVPNTunnel()
        try await waitFor("provider starts", seconds: 20) { [.connecting, .connected, .reasserting].contains(manager.connection.status) }
        manager.connection.stopVPNTunnel()
        try await waitFor("stop during start") { manager.connection.status == .disconnected }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNotEqual(snapshot(defaults)["status"] as? String, "connected")

        for cycle in 1...2 {
            let cycleStarted = Date()
            try manager.connection.startVPNTunnel()
            try await waitFor("cycle \(cycle) connected", seconds: 90) {
                manager.connection.status == .connected && self.snapshot(defaults)["status"] as? String == "connected"
            }
            let state = snapshot(defaults)
            XCTAssertFalse((state["relayName"] as? String ?? "").isEmpty)
            XCTAssertNotNil(state["relayClass"] as? String)
            XCTAssertEqual(defaults.string(forKey: "client_id"), installID)
            let session = try XCTUnwrap(defaults.data(forKey: "telemetry_session"))
            let identity = try JSONSerialization.jsonObject(with: session) as! [String: Any]
            XCTAssertFalse((identity["id"] as? String ?? "").isEmpty)
            // Let Go monitoring and traffic accounting run on the actual TUN.
            try await Task.sleep(nanoseconds: 20_000_000_000)
            XCTAssertEqual(manager.connection.status, .connected)
            manager.connection.stopVPNTunnel()
            try await waitFor("cycle \(cycle) stopped") { manager.connection.status == .disconnected }
            XCTAssertEqual(snapshot(defaults)["status"] as? String, "disconnected")
            XCTAssertNil(defaults.data(forKey: "telemetry_session"))
            if let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.openrung.app"),
               let data = try? Data(contentsOf: directory.appendingPathComponent("engine-memory.json")) {
                let memory = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "cycle-\(cycle)-extension-memory"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("B3 physical memory cycle \(cycle): \(memory)")
                let peak = try XCTUnwrap(memory["sampled_peak_bytes"] as? Double)
                let measuredAt = try XCTUnwrap((memory["measured_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
                XCTAssertGreaterThanOrEqual(measuredAt.timeIntervalSince(cycleStarted), -1, "Stale memory report from an earlier run")
                XCTAssertGreaterThan(peak, 0)
                XCTAssertGreaterThan(memory["samples"] as? Int ?? 0, 10, "Missing running-extension samples")
                if let budget = memoryBudget {
                    XCTAssertLessThanOrEqual(peak, budget * 1_048_576, "Running extension exceeds the maintainer's memory budget")
                }
            } else { XCTFail("Build PacketTunnel with OPENRUNG_MEMORY_DIAGNOSTICS for the memory trace") }
        }
    }

    private func snapshot(_ defaults: UserDefaults) -> [String: Any] {
        guard let data = defaults.data(forKey: "connection_state"),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private func waitFor(_ stage: String, seconds: TimeInterval = 30, condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else {
                let defaults = UserDefaults(suiteName: "group.com.openrung.app")!
                let state = snapshot(defaults)
                // Keep diagnostic logs, never descriptor credentials or the outbox.
                print("B3 device timeout at \(stage): \(state)")
                throw NSError(domain: "B3 device", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(stage)"])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}
