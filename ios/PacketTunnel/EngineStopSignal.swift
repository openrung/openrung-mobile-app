import Foundation

/// A replayable, cancellation-safe terminal signal for the embedded tunnel engine.
///
/// Startup verification and the long-lived engine monitor wait on the same signal in sequence.
/// Cancelling either wait must therefore remove only that waiter; it must not consume or finish the
/// signal for a later waiter. Once completed, the result is retained and returned to every future
/// waiter.
final class EngineStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var unexpectedReason: String?
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<String?, Never>] = [:]

    var hasUnexpectedStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unexpectedReason != nil
    }

    func reportUnexpected(_ reason: String) {
        complete(with: reason)
    }

    /// Atomically claims the terminal transition for an intentional engine stop.
    /// Returns false only when an unexpected stop won the race first.
    @discardableResult
    func finishExpected() -> Bool {
        lock.lock()
        if unexpectedReason != nil {
            lock.unlock()
            return false
        }
        guard finished == false else {
            lock.unlock()
            return true
        }
        finished = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: nil)
        }
        return true
    }

    func wait() async -> String? {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let unexpectedReason {
                    lock.unlock()
                    continuation.resume(returning: unexpectedReason)
                    return
                }
                guard finished == false, Task.isCancelled == false else {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                waiters[waiterID] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: waiterID)
            lock.unlock()
            continuation?.resume(returning: nil)
        }
    }

    private func complete(with reason: String?) {
        lock.lock()
        guard finished == false else {
            lock.unlock()
            return
        }
        unexpectedReason = reason
        finished = true
        let continuations = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.resume(returning: reason)
        }
    }
}
