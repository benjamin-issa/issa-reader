import Foundation
import Testing

@testable import IssaReader_iOS

/// The wait an account's departure gives Spotlight.
///
/// `SpotlightIndex.clear()` awaited the system's deletion outright, in line
/// with sign-out and an account switch, and on a simulator whose Spotlight
/// service never answered that wait never ended: the arriving account never
/// reached its library (AccountSwitchDrainTests hung for good). The work these
/// tests hand over is slow rather than stuck, so a wait that is not bounded
/// fails here, late, instead of hanging the run.
@Suite("Waiting for work that may never answer")
struct BoundedWaitTests {
    @Test("slow work is waited for no longer than the limit, and still finishes")
    func slowWorkIsNotWaitedFor() async throws {
        let done = Flag()
        let started = ContinuousClock.now

        let finished = await BoundedWait.run(for: .milliseconds(200)) {
            try? await Task.sleep(for: .seconds(5))
            done.set()
        }

        #expect(!finished)
        #expect(ContinuousClock.now - started < .seconds(3), "the caller was held by the work")
        #expect(!done.isSet)
        for _ in 0 ..< 200 where !done.isSet {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(done.isSet, "the work has to run to its end after the wait gives up")
    }

    @Test("work that finishes in time is waited for")
    func quickWorkIsWaitedFor() async {
        let done = Flag()
        let finished = await BoundedWait.run(for: .seconds(5)) { done.set() }
        #expect(finished)
        #expect(done.isSet)
    }

    /// The caller in production: whatever Spotlight does, an account's
    /// departure is not held past the limit.
    @Test("clearing Spotlight returns within its limit")
    func spotlightClearIsBounded() async {
        let started = ContinuousClock.now
        await SpotlightIndex.clear()
        #expect(ContinuousClock.now - started < SpotlightIndex.clearWait + .seconds(2))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
