import Foundation

protocol PacketTunnelEngine: AnyObject {
    func start(broker: String, country: String, relay: String) throws
    func stop() throws
    var teardownComplete: Bool { get }
    func pause()
    func resume()
    func networkChanged(_ snapshot: EngineNetworkSnapshot) throws
}

protocol PacketTunnelEngineOwner: AnyObject {
    func observeNetwork(_ receive: @escaping (EngineNetworkSnapshot) -> Void)
    func closeNetworkObservation()
    func receiveEngineEvent(_ event: EngineEvent)
    func engineStopping()
    func engineStopped(error: Error?, startPending: Bool)
    func engineTeardownFailed(_ error: Error, startPending: Bool)
}

enum PacketTunnelEngineError: LocalizedError {
    case unavailable, noOwner, teardown, missingNetwork
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The VPN engine is not linked."
        case .noOwner: return "The packet tunnel owner is no longer active."
        case .teardown: return "VPN teardown did not finish. The provider must be restarted."
        case .missingNetwork: return "The physical network observation did not become available."
        }
    }
}

/// One engine/outbox per extension process. Only this queue calls its lifecycle
/// API. Go host callbacks borrow the locked owner without waiting on this queue
/// (Stop joins Go workers, so a synchronous hop here would deadlock).
final class PacketTunnelEngineHost {
    typealias Factory = (EngineEventDispatcher) throws -> any PacketTunnelEngine
    private let queue: DispatchQueue
    private let factory: Factory
    private let diagnostic: (String) -> Void
    private var engine: (any PacketTunnelEngine)?
    private let ownerLock = NSLock()
    private var owner: (any PacketTunnelEngineOwner)?
    private var lease = UUID()
    private var startCompletion: ((Error?) -> Void)?
    private var terminating = false
    private var waitingForNetwork = false
    private var sleeping = false
    private lazy var events = EngineEventDispatcher(post: { [queue] work in queue.async(execute: work) }, invalid: { [diagnostic] in diagnostic("Invalid connectcore event envelope") })

    init(queue: DispatchQueue = DispatchQueue(label: "com.openrung.app.engine-control"), diagnostic: @escaping (String) -> Void = { _ in }, factory: @escaping Factory) {
        self.queue = queue
        self.diagnostic = diagnostic
        self.factory = factory
    }

    func currentOwner() -> (any PacketTunnelEngineOwner)? {
        ownerLock.lock(); defer { ownerLock.unlock() }
        return owner
    }

    private func setOwner(_ value: (any PacketTunnelEngineOwner)?) {
        ownerLock.lock(); owner = value; ownerLock.unlock()
    }

    func start(owner: any PacketTunnelEngineOwner, broker: String, country: String, relay: String, completion: @escaping (Error?) -> Void) {
        queue.async { [self] in
            guard !terminating else { completion(PacketTunnelEngineError.teardown); return }
            events.detach()
            if !stopEngine() {
                failTeardown()
                finishStart(PacketTunnelEngineError.teardown)
                completion(PacketTunnelEngineError.teardown)
                return
            }
            finishStart(CancellationError())
            releaseOwner()
            setOwner(owner)
            startCompletion = completion
            sleeping = false
            let token = UUID()
            lease = token
            waitingForNetwork = true
            events.attach { [weak self] event in self?.consume(event, token: token) }
            do {
                if engine == nil { engine = try factory(events) }
                owner.observeNetwork { [weak self] snapshot in
                    self?.queue.async { [weak self] in
                        guard let self, self.lease == token, self.currentOwner() === owner, !self.terminating else { return }
                        do {
                            try self.engine?.networkChanged(snapshot)
                            if self.waitingForNetwork {
                                self.waitingForNetwork = false
                                if !self.sleeping { self.engine?.resume() }
                                try self.engine?.start(broker: broker, country: country, relay: relay)
                            }
                        } catch { self.fail(error) }
                    }
                }
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.lease == token, self.waitingForNetwork else { return }
                    self.fail(PacketTunnelEngineError.missingNetwork)
                }
            } catch { fail(error) }
        }
    }

    func stop(owner: any PacketTunnelEngineOwner, completion: @escaping () -> Void) {
        queue.async { [self] in
            guard !terminating, currentOwner() === owner else { completion(); return }
            events.detach()
            waitingForNetwork = false
            owner.engineStopping()
            if !stopEngine() { failTeardown(); finishStart(PacketTunnelEngineError.teardown); completion(); return }
            owner.engineStopped(error: nil, startPending: startCompletion != nil)
            finishStart(CancellationError())
            releaseOwner()
            completion()
        }
    }

    func sleep(owner: any PacketTunnelEngineOwner, completion: @escaping () -> Void) {
        queue.async { [self] in
            if currentOwner() === owner && !terminating { sleeping = true; engine?.pause() }
            completion()
        }
    }

    func wake(owner: any PacketTunnelEngineOwner) {
        queue.async { [self] in
            guard currentOwner() === owner, !terminating else { return }
            sleeping = false
            // Network callbacks keep flowing while asleep. The engine sees the
            // latest epoch before resuming; wake itself never invents an epoch.
            engine?.resume()
        }
    }

    private func consume(_ event: EngineEvent, token: UUID) {
        guard lease == token, let owner = currentOwner(), !terminating else { return }
        owner.receiveEngineEvent(event)
        if event.status == .connected { finishStart(nil) }
        if event.status == .failed {
            fail(NSError(domain: "OpenRungEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: event.payload["LastError"] as? String ?? "VPN connection failed"]))
        }
    }

    private func fail(_ error: Error) {
        events.detach()
        waitingForNetwork = false
        let complete = stopEngine()
        if !complete { failTeardown(); finishStart(error); return }
        // NE may suspend the extension as soon as completion fires. Persist
        // terminal state first and tell the owner which NE failure signal to use.
        currentOwner()?.engineStopped(error: error, startPending: startCompletion != nil)
        finishStart(error)
        releaseOwner()
    }

    private func failTeardown() {
        guard !terminating else { return }
        terminating = true
        waitingForNetwork = false
        events.detach()
        currentOwner()?.closeNetworkObservation()
        currentOwner()?.engineTeardownFailed(PacketTunnelEngineError.teardown, startPending: startCompletion != nil)
        // Retain the owner and reject reuse while libbox may hold its TUN.
    }

    private func stopEngine() -> Bool {
        guard let engine else { return true }
        do { try engine.stop() } catch { diagnostic("Engine shutdown: \(error.localizedDescription)") }
        return engine.teardownComplete // Upload timeout alone permits reuse.
    }

    private func finishStart(_ error: Error?) {
        let completion = startCompletion
        startCompletion = nil
        completion?(error)
    }

    private func releaseOwner() {
        events.detach()
        waitingForNetwork = false
        currentOwner()?.closeNetworkObservation()
        setOwner(nil)
        lease = UUID()
    }
}
