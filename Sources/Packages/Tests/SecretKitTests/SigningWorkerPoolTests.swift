import Foundation
import Testing
@testable import SecretKit

@Suite struct SigningWorkerPoolTests {

    @Test func runsWorkOnAWorker() async throws {
        let pool = SigningWorkerPool(maxConcurrentWorkers: 2, timeout: .seconds(5))
        let value = try await pool.perform { 42 }
        #expect(value == 42)
    }

    @Test func propagatesErrorsAndReclaimsTheWorker() async throws {
        struct TestError: Error {}
        let pool = SigningWorkerPool(maxConcurrentWorkers: 1, timeout: .seconds(5))
        await #expect(throws: TestError.self) {
            try await pool.perform { throw TestError() }
        }
        let value = try await pool.perform { 1 }
        #expect(value == 1)
    }

    @Test func timesOutWhenWorkDoesNotReturn() async throws {
        let pool = SigningWorkerPool(maxConcurrentWorkers: 4, timeout: .milliseconds(200))
        await #expect(throws: SigningWorkerPool.Failure.timedOut) {
            try await pool.perform {
                Thread.sleep(forTimeInterval: 30)
            }
        }
    }

    @Test func refusesWorkWhileAllWorkersAreStuck() async throws {
        let pool = SigningWorkerPool(maxConcurrentWorkers: 2, timeout: .milliseconds(200))

        async let first: Void? = try? await pool.perform {
            Thread.sleep(forTimeInterval: 30)
        }
        async let second: Void? = try? await pool.perform {
            Thread.sleep(forTimeInterval: 30)
        }
        _ = await (first, second)

        await #expect(throws: SigningWorkerPool.Failure.busy) {
            try await pool.perform { 0 }
        }
    }

    @Test func reclaimsWorkersThatReturnAfterTheDeadline() async throws {
        let pool = SigningWorkerPool(maxConcurrentWorkers: 1, timeout: .milliseconds(100))
        await #expect(throws: SigningWorkerPool.Failure.timedOut) {
            try await pool.perform {
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        try await Task.sleep(for: .seconds(2))
        let value = try await pool.perform { 7 }
        #expect(value == 7)
    }

}
