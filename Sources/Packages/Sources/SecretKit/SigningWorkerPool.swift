import Foundation
import OSLog

/// Runs potentially blocking signing operations (Secure Enclave, smart card) on dedicated
/// worker threads instead of Swift's cooperative pool.
///
/// Blocking a cooperative thread starves the whole agent: a single wedged synchronous
/// XPC call can make every later request — even identity lookups — hang. This pool moves
/// such calls onto threads of their own, bounds how many can run at once, and turns a
/// worker that never returns into a fast, explicit failure instead of a silent hang.
public actor SigningWorkerPool {

    public enum Failure: Error, Equatable {
        /// Every worker is occupied, so new work is refused.
        case busy
        /// The worker did not return before the deadline.
        case timedOut
    }

    private let maxConcurrentWorkers: Int
    private let timeout: Duration

    /// Workers that have been started and have not returned yet. A worker that hits the
    /// deadline keeps counting until its thread eventually returns (if it ever does),
    /// so the pool can never grow past ``maxConcurrentWorkers``.
    private var occupiedWorkers = 0

    private let logger = Logger(subsystem: "com.maxgoedjen.secretive", category: "SigningWorkerPool")

    /// Creates a pool.
    /// - Parameters:
    ///   - maxConcurrentWorkers: The maximum number of simultaneously running workers.
    ///   - timeout: How long a single worker may run before the request fails.
    public init(maxConcurrentWorkers: Int = 4, timeout: Duration = .seconds(30)) {
        self.maxConcurrentWorkers = maxConcurrentWorkers
        self.timeout = timeout
    }

    /// Runs `work` on a dedicated worker thread and returns its result.
    ///
    /// Throws ``Failure/busy`` when every worker is occupied, and ``Failure/timedOut``
    /// when the worker does not return within the timeout. Synchronous XPC calls cannot
    /// be cancelled, so a worker that hits the deadline keeps running — and keeps
    /// counting against ``maxConcurrentWorkers`` — until it returns.
    public func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard occupiedWorkers < maxConcurrentWorkers else {
            logger.error("All \(self.maxConcurrentWorkers) signing workers are occupied; refusing new work")
            throw Failure.busy
        }
        occupiedWorkers += 1

        let timeout = self.timeout
        do {
            let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                let arbiter = WorkerArbiter(continuation: continuation) { [self] in
                    Task { await self.reclaimLateWorker() }
                }

                let thread = Thread {
                    arbiter.finish(with: Result { try work() })
                }
                thread.name = "com.maxgoedjen.secretive.signing-worker"
                thread.qualityOfService = .userInitiated
                thread.start()

                Task.detached {
                    try? await Task.sleep(for: timeout)
                    arbiter.expire()
                }
            }
            occupiedWorkers -= 1
            return value
        } catch is WorkerDeadlineExceeded {
            logger.error("Signing worker did not return within \(self.timeout); request failed")
            throw Failure.timedOut
        } catch {
            occupiedWorkers -= 1
            throw error
        }
    }

    /// A worker that outlived its deadline has, against expectations, returned.
    private func reclaimLateWorker() {
        if occupiedWorkers > 0 {
            occupiedWorkers -= 1
        }
    }

}

/// Thrown by ``WorkerArbiter`` when a worker outlives its deadline.
private struct WorkerDeadlineExceeded: Error {}

/// Resumes the request exactly once — either with the worker's result or with the
/// deadline — and reports results that arrive after the deadline has already fired.
private final class WorkerArbiter<T: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private let continuation: CheckedContinuation<T, any Error>
    private let onLateCompletion: @Sendable () -> Void
    private var hasCompleted = false

    init(continuation: CheckedContinuation<T, any Error>, onLateCompletion: @escaping @Sendable () -> Void) {
        self.continuation = continuation
        self.onLateCompletion = onLateCompletion
    }

    /// Called by the worker thread when the operation returns.
    func finish(with result: Result<T, any Error>) {
        lock.lock()
        let isFirst = !hasCompleted
        hasCompleted = true
        lock.unlock()

        if isFirst {
            continuation.resume(with: result)
        } else {
            // The deadline already failed this request; the worker has now come back.
            onLateCompletion()
        }
    }

    /// Called when the deadline fires.
    func expire() {
        lock.lock()
        let isFirst = !hasCompleted
        hasCompleted = true
        lock.unlock()

        if isFirst {
            continuation.resume(throwing: WorkerDeadlineExceeded())
        }
    }

}
