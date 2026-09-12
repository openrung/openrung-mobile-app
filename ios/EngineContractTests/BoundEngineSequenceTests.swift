import Foundation
import XCTest
import Libbox

/// A4's unchanged expectations run through generated ObjC/Swift bindings and
/// the shipping dispatcher. The isolated framework exposes only network/clock/
/// process seams, exactly like the Go and Kotlin contract suites.
final class BoundEngineSequenceTests: XCTestCase {
    func testAllVendoredSequences() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("testdata/contract/event_sequence.json")
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        XCTAssertEqual(vectors["version"] as? Int, 1)
        for scenario in vectors["scenarios"] as! [[String: Any]] {
            try run(scenario)
        }
    }

    private func run(_ scenario: [String: Any]) throws {
        let queue = DispatchQueue(label: "openrung.swift-contract")
        var statuses: [String] = []
        var notices: [[String: Any]] = []
        var invalid = false
        let dispatcher = EngineEventDispatcher(post: { queue.async(execute: $0) }, invalid: { invalid = true })
        queue.sync {
            dispatcher.attach { event in
                if event.kind == "state", let status = event.payload["Status"] as? String, statuses.last != status { statuses.append(status) }
                if event.kind == "notice" {
                    var notice: [String: Any] = ["kind": event.payload["Kind"] as? String ?? ""]
                    for (source, target) in ["RelayID": "relay_id", "FromRelayID": "from_relay_id", "FrontID": "front_id"] {
                        if let value = event.payload[source] as? String, !value.isEmpty { notice[target] = value }
                    }
                    for (source, target) in ["Failures": "failures", "Threshold": "threshold"] {
                        if let value = event.payload[source] as? Int, value != 0 { notice[target] = value }
                    }
                    notices.append(notice)
                }
            }
        }
        let listener = ContractListener(dispatcher)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var error: NSError?
        let json = String(decoding: try JSONSerialization.data(withJSONObject: scenario), as: UTF8.self)
        let harness = try XCTUnwrap(LibboxNewOpenRungContractScenario(json, directory.path, listener, &error), error?.localizedDescription ?? "scenario constructor")
        defer { try? harness.close(); queue.sync { dispatcher.detach() } }
        let engine = try XCTUnwrap(harness.engine())
        for step in scenario["steps"] as! [[String: Any]] {
            func awaitOutput(_ predicate: () -> Bool) throws {
                let deadline = Date().addingTimeInterval(12)
                while !queue.sync(execute: predicate) {
                    guard Date() < deadline else { throw NSError(domain: "A4 timeout \(scenario["id"]!) \(step)", code: 1) }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            switch step["do"] as! String {
            case "connect": try engine.start(harness.brokerURL(), country: "", relayID: "")
            case "disconnect": try engine.disconnect()
            case "shutdown": try engine.stop((step["flush_budget_ms"] as? NSNumber)?.int64Value ?? 0)
            case "network": try engine.networkChanged(step["up"] as! Bool, fingerprint: step["fingerprint"] as? String ?? "", dnsServersJSON: "[]")
            case "await_status": try awaitOutput { statuses.filter { $0 == step["status"] as? String }.count >= (step["count"] as? Int ?? 1) }
            case "await_notice": try awaitOutput { notices.filter { $0["kind"] as? String == step["kind"] as? String }.count >= (step["count"] as? Int ?? 1) }
            case "crash_tunnel": try harness.crashTunnel()
            case "await_ready_hold": try harness.awaitReadyHold()
            case "release_ready": harness.releaseReady()
            default: XCTFail("Unknown A4 step: \(step)")
            }
        }
        try engine.stop(1_000)
        let actual: [String: Any] = try queue.sync {
            ["statuses": statuses, "notices": notices, "events": try JSONSerialization.jsonObject(with: Data(harness.eventsJSON().utf8))]
        }
        XCTAssertTrue(NSDictionary(dictionary: actual).isEqual(to: scenario["expect"] as! [String: Any]), "\(scenario["id"]!): \(actual)")
        XCTAssertFalse(queue.sync { invalid })
        print("A4 Swift passed: \(scenario["id"]!)")
    }
}

private final class ContractListener: NSObject, LibboxOpenRungEngineListenerProtocol {
    private let dispatcher: EngineEventDispatcher
    init(_ dispatcher: EngineEventDispatcher) { self.dispatcher = dispatcher }
    func onEvent(_ raw: String?) { dispatcher.onEvent(raw) }
}
