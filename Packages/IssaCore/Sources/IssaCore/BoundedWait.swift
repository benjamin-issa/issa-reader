import Foundation

/// Waits for some work, or for a deadline, whichever comes first — and never
/// cancels the work.
///
/// For work a caller cannot cancel and must not be held by: the work runs in a
/// task of its own and goes on after the wait ends. A task group cannot do
/// this, because it waits for every child, so the loser has to be cancelled —
/// and a child stuck in a call that ignores cancellation holds the group as
/// surely as awaiting it directly, while a cancelled request is one that was
/// never sent.
///
/// One for the whole app. Sign-out's token revoke (`Session`) and Spotlight's
/// clear on an account's departure each had a private copy, and the copies had
/// already drifted: only one cancelled its timer when the work won, so every
/// sign-out left a three-second sleep running to a no-op.
public enum BoundedWait {
    /// - Returns: whether the work finished before the deadline.
    @discardableResult
    public static func run(
        for limit: Duration, _ work: @escaping @Sendable () async -> Void,
    ) async -> Bool {
        await run(for: limit, sleep: { try await Task.sleep(for: $0) }, work)
    }

    /// The same, with the deadline's sleep handed in, so a test can see the
    /// timer let go of once the work has won.
    static func run(
        for limit: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        _ work: @escaping @Sendable () async -> Void,
    ) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            once.hold(continuation)
            let timer = Task.detached {
                try? await sleep(limit)
                once.resume(returning: false)
            }
            Task.detached {
                await work()
                once.resume(returning: true)
                timer.cancel()
            }
        }
    }

    /// Resumes a continuation exactly once, whichever side gets there first.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func hold(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func resume(returning value: Bool) {
            let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: value)
        }
    }
}
