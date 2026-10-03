import Foundation
import Synchronization
import Testing

@testable import IssaCore

/// The one bounded wait, shared by sign-out's revoke and Spotlight's clear.
@Suite("Waiting for work, or for a deadline")
struct CoreBoundedWaitTests {
    @Test("slow work is waited for no longer than the limit, and still finishes")
    func slowWork() async throws {
        let done = Mutex(false)
        let started = ContinuousClock.now
        let finished = await BoundedWait.run(for: .milliseconds(200)) {
            try? await Task.sleep(for: .seconds(2))
            done.withLock { $0 = true }
        }
        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(1.5), "the caller was held by the work")
        #expect(!done.withLock { $0 })
        for _ in 0 ..< 100 where !done.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(done.withLock { $0 }, "the work has to run to its end after the wait gives up")
    }

    @Test("work that finishes in time is waited for")
    func quickWork() async {
        let done = Mutex(false)
        let finished = await BoundedWait.run(for: .seconds(5)) { done.withLock { $0 = true } }
        #expect(finished)
        #expect(done.withLock { $0 })
    }

    /// The copy the app kept never let go of its timer, so every sign-out
    /// left a detached sleep running out its full limit to a no-op.
    @Test("the deadline's timer is let go of once the work has won")
    func timerIsCancelled() async throws {
        let cancelled = Mutex(false)
        let finished = await BoundedWait.run(for: .seconds(30), sleep: { limit in
            try await withTaskCancellationHandler {
                try await Task.sleep(for: limit)
            } onCancel: {
                cancelled.withLock { $0 = true }
            }
        }) {}
        #expect(finished)
        for _ in 0 ..< 100 where !cancelled.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(cancelled.withLock { $0 }, "the timer was left sleeping after the work finished")
    }
}
