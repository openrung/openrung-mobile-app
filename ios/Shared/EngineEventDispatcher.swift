import Foundation

struct EngineEvent {
    let sequence: UInt64
    let kind: String
    let payload: [String: Any]

    var status: ConnectionStatus? {
        guard kind == "state", let value = payload["Status"] as? String else { return nil }
        return ConnectionStatus(rawValue: value.lowercased())
    }
}

/// Go callbacks only enqueue. Attachment identity is captured BEFORE enqueueing,
/// so buffered events cannot update a replacement provider. Attach/detach and
/// delivery run on the host's serial queue; the capture itself is lock protected.
final class EngineEventDispatcher {
    private final class Attachment {
        let receive: (EngineEvent) -> Void
        init(_ receive: @escaping (EngineEvent) -> Void) { self.receive = receive }
    }
    private let lock = NSLock()
    private var attachment: Attachment?
    private var lastSequence: UInt64 = 0
    private let post: (@escaping () -> Void) -> Void
    private let invalid: () -> Void

    init(post: @escaping (@escaping () -> Void) -> Void, invalid: @escaping () -> Void = {}) {
        self.post = post
        self.invalid = invalid
    }

    func attach(_ receive: @escaping (EngineEvent) -> Void) {
        lock.lock()
        attachment = Attachment(receive)
        lastSequence = 0
        lock.unlock()
    }

    func detach() {
        lock.lock()
        attachment = nil
        lock.unlock()
    }

    func onEvent(_ raw: String?) {
        lock.lock()
        let destination = attachment
        lock.unlock()
        guard let destination else { return }
        post { [self] in
            lock.lock()
            let current = attachment === destination
            lock.unlock()
            guard current else { return }
            guard let raw, let data = raw.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = envelope["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version == 1,
                  let number = envelope["sequence"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let sequence = UInt64(number.stringValue), sequence > 0,
                  let kind = envelope["kind"] as? String, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let payload = envelope["payload"] as? [String: Any] else { invalid(); return }
            guard sequence > lastSequence else { return }
            lastSequence = sequence
            guard ["state", "notice", "log"].contains(kind) else { return }
            destination.receive(EngineEvent(sequence: sequence, kind: kind, payload: payload))
        }
    }
}
