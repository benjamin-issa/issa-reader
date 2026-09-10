import Foundation
import Testing

@testable import IssaAsk

/// The turn itself, without an engine or a model around it.
///
/// The bug this type exists for is not visible from here — it was that the turn
/// lived on `AskEngine` while `AskCoordinator` built a fresh engine per
/// question, so nothing shared it. That is asserted in `AskEngineTests` and in
/// `AskCoordinatorTests`. What is asserted here is that the turn is worth
/// sharing: that a waiter really waits, that waiters are let through in the
/// order they arrived, that a throwing body still releases — a body that
/// throws without releasing wedges every later question in the process, with
/// no error and nothing in the log — and that `ifFree` skips rather than
/// queues.
@Suite("One turn at the model")
struct AskTurnstileTests {
    /// Somewhere for the bodies to record what happened, in order.
    actor Trace {
        private(set) var entries: [String] = []
        func add(_ entry: String) { entries.append(entry) }
    }

    /// A gate a test can hold a turn open with, without racing a sleep.
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var hasArrived = false

        func wait() async {
            hasArrived = true
            for arrival in arrivals { arrival.resume() }
            arrivals.removeAll()
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        /// Suspends until somebody is actually inside `wait()`.
        func waitUntilHeld() async {
            guard !hasArrived else { return }
            await withCheckedContinuation { arrivals.append($0) }
        }

        func open() {
            isOpen = true
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }
    }

    @Test("a second body waits for the first to finish")
    func aSecondBodyWaits() async throws {
        let turnstile = AskTurnstile()
        let gate = Gate()
        let trace = Trace()

        let first = Task {
            await turnstile.withTurn {
                await trace.add("first in")
                await gate.wait()
                await trace.add("first out")
            }
        }
        await gate.waitUntilHeld()

        let second = Task {
            await turnstile.withTurn { await trace.add("second in") }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await trace.entries == ["first in"])

        await gate.open()
        await first.value
        await second.value
        #expect(await trace.entries == ["first in", "first out", "second in"])
    }

    @Test("waiters are let through in the order they arrived")
    func theQueueIsFirstInFirstOut() async throws {
        let turnstile = AskTurnstile()
        let gate = Gate()
        let trace = Trace()

        let holder = Task {
            await turnstile.withTurn { await gate.wait() }
        }
        await gate.waitUntilHeld()

        // Twenty milliseconds between each, which is a hope about scheduling
        // rather than a guarantee — but the thing hoped for is a single actor
        // hop, which is four orders of magnitude cheaper, and the alternative
        // is production API on the turnstile that exists only for this test.
        var waiters: [Task<Void, Never>] = []
        for index in 1 ... 4 {
            let task = Task {
                await turnstile.withTurn { await trace.add("\(index)") }
            }
            waiters.append(task)
            try await Task.sleep(for: .milliseconds(20))
        }

        await gate.open()
        await holder.value
        for waiter in waiters { await waiter.value }
        #expect(await trace.entries == ["1", "2", "3", "4"])
    }

    @Test("a body that throws still gives the turn back")
    func aThrowingBodyGivesTheTurnBack() async throws {
        struct Boom: Error {}
        let turnstile = AskTurnstile()

        await #expect(throws: Boom.self) {
            try await turnstile.withTurn { throw Boom() }
        }
        // If the throw had kept the turn, this would never return.
        let ran = await turnstile.ifFree {}
        #expect(ran)
    }

    @Test("a body's value comes back out")
    func theValueIsReturned() async throws {
        let turnstile = AskTurnstile()
        #expect(await turnstile.withTurn { 41 + 1 } == 42)
    }

    @Test("work that would have to wait is skipped rather than queued")
    func ifFreeSkipsWhileTheTurnIsHeld() async throws {
        let turnstile = AskTurnstile()
        let gate = Gate()
        let trace = Trace()

        let holder = Task {
            await turnstile.withTurn { await gate.wait() }
        }
        await gate.waitUntilHeld()

        // A prewarm that has to wait is pointless: whatever it would load, the
        // question holding the turn has loaded already.
        let ran = await turnstile.ifFree { await trace.add("prewarmed") }
        #expect(!ran)
        #expect(await trace.entries.isEmpty)

        await gate.open()
        await holder.value
        #expect(await turnstile.ifFree { await trace.add("prewarmed") })
        #expect(await trace.entries == ["prewarmed"])
    }
}
