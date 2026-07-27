import Foundation

final class TestLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    @discardableResult
    func mutate<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

final class TestNativeBrokerFactory: NativeBrokerOperationFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var operations: [(any NativeBrokerOperation)?]
    private var storedMakeCount = 0

    init(_ operations: [(any NativeBrokerOperation)?]) {
        self.operations = operations
    }

    convenience init(operation: (any NativeBrokerOperation)?) {
        self.init([operation])
    }

    func makeOperation() -> (any NativeBrokerOperation)? {
        lock.lock()
        defer { lock.unlock() }
        storedMakeCount += 1
        return operations.isEmpty ? nil : operations.removeFirst()
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedMakeCount
    }
}

final class TestNativeBrokerOperation: NativeBrokerOperation, @unchecked Sendable {
    typealias RelayHandler = @Sendable (String, Int32, String, String) -> NativeBrokerRelayResultSnapshot?
    typealias TelemetryHandler = @Sendable (String, String) -> NativeBrokerResultSnapshot?
    typealias SpeedTestHandler = @Sendable (String) -> NativeBrokerSpeedTestResultSnapshot?
    typealias ManifestHandler = @Sendable (String) -> NativeBrokerManifestResultSnapshot?
    typealias TicketHandler = @Sendable (
        String,
        String,
        String,
        String,
        String
    ) -> NativeBrokerWSSTicketResultSnapshot?

    var relayHandler: RelayHandler?
    var telemetryHandler: TelemetryHandler?
    var speedTestHandler: SpeedTestHandler?
    var manifestHandler: ManifestHandler?
    var ticketHandler: TicketHandler?
    var closeHandler: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var storedCloseCount = 0

    func firstReachable(
        primary: String,
        limit: Int32,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerRelayResultSnapshot? {
        relayHandler?(primary, limit, clientID, sessionID)
    }

    func sendTelemetryBatchJSON(
        brokerURL: String,
        batchJSON: String
    ) -> NativeBrokerResultSnapshot? {
        telemetryHandler?(brokerURL, batchJSON)
    }

    func runSpeedTest(
        brokerURL: String
    ) -> NativeBrokerSpeedTestResultSnapshot? {
        speedTestHandler?(brokerURL)
    }

    func fetchManifestCandidate(
        candidateURL: String
    ) -> NativeBrokerManifestResultSnapshot? {
        manifestHandler?(candidateURL)
    }

    func requestWSSTicket(
        brokerURL: String,
        relayID: String,
        frontID: String,
        clientID: String,
        sessionID: String
    ) -> NativeBrokerWSSTicketResultSnapshot? {
        ticketHandler?(brokerURL, relayID, frontID, clientID, sessionID)
    }

    func close() {
        lock.lock()
        storedCloseCount += 1
        let handler = closeHandler
        lock.unlock()
        handler?()
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCloseCount
    }
}

/// A fake synchronous native call that only returns after `close()` is invoked.
final class BlockingNativeBrokerOperation: NativeBrokerOperation, @unchecked Sendable {
    private let condition = NSCondition()
    private var started = false
    private var closed = false
    private var storedCloseCount = 0

    private func block<Result>(_ result: Result) -> Result {
        condition.lock()
        started = true
        condition.broadcast()
        while closed == false {
            condition.wait()
        }
        condition.unlock()
        return result
    }

    func firstReachable(
        primary _: String,
        limit _: Int32,
        clientID _: String,
        sessionID _: String
    ) -> NativeBrokerRelayResultSnapshot? {
        block(
            NativeBrokerRelayResultSnapshot(
                succeeded: false,
                errorKind: "cancelled"
            )
        )
    }

    func sendTelemetryBatchJSON(
        brokerURL _: String,
        batchJSON _: String
    ) -> NativeBrokerResultSnapshot? {
        block(NativeBrokerResultSnapshot(succeeded: false, errorKind: "cancelled"))
    }

    func runSpeedTest(
        brokerURL _: String
    ) -> NativeBrokerSpeedTestResultSnapshot? {
        block(NativeBrokerSpeedTestResultSnapshot(succeeded: false, errorKind: "cancelled"))
    }

    func fetchManifestCandidate(
        candidateURL _: String
    ) -> NativeBrokerManifestResultSnapshot? {
        block(NativeBrokerManifestResultSnapshot(succeeded: false, errorKind: "cancelled"))
    }

    func requestWSSTicket(
        brokerURL _: String,
        relayID _: String,
        frontID _: String,
        clientID _: String,
        sessionID _: String
    ) -> NativeBrokerWSSTicketResultSnapshot? {
        block(
            NativeBrokerWSSTicketResultSnapshot(
                succeeded: false,
                errorKind: "cancelled"
            )
        )
    }

    func close() {
        condition.lock()
        storedCloseCount += 1
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    func waitUntilStarted(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while started == false, condition.wait(until: deadline) {
            // Re-check under the condition lock.
        }
        return started
    }

    var closeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedCloseCount
    }

    func waitUntilClosed(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while closed == false, condition.wait(until: deadline) {
            // Re-check under the condition lock.
        }
        return closed
    }
}
