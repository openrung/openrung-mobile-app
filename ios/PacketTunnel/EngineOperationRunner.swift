import Foundation

/// Bridges a cancellable Swift probe to the synchronous gomobile callback. A
/// cancellation closes the provider's sockets through their task handlers and
/// joins the task before Go can close libbox or release this run's TUN settings.
enum EngineOperationRunner {
    static func run<T: Sendable>(cancelled: @escaping () -> Bool, work: @escaping @Sendable () async throws -> T) throws -> T {
        if cancelled() { throw CancellationError() }
        let completed = DispatchSemaphore(value: 0)
        let result = OperationResult<T>()
        let task = Task.detached {
            do { result.store(.success(try await work())) }
            catch { result.store(.failure(error)) }
            completed.signal()
        }
        while completed.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if cancelled() { task.cancel() }
        }
        if cancelled() { throw CancellationError() }
        return try result.load().get()
    }
}

private final class OperationResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<T, Error>?
    func store(_ value: Result<T, Error>) { lock.lock(); self.value = value; lock.unlock() }
    func load() -> Result<T, Error> { lock.lock(); defer { lock.unlock() }; return value! }
}
