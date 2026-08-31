import Foundation
import GRDB
import Testing

@testable import IssaCore

/// `MutationQueue` and `LibraryStore` open two independent connections to the
/// same SQLite file. Proving the busy-timeout fix means proving both halves of
/// it: that real lock contention between those two connections actually
/// happens, and that `MutationQueue`'s connection now waits it out instead of
/// throwing the instant it collides.
///
/// `DispatchSemaphore.wait()` is unavailable from an `async` context, so every
/// blocking wait here is pushed into a plain synchronous closure and bridged
/// back with a continuation — never called directly inside a test's `async`
/// body.
struct MutationQueueLockingTests {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-lock-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func waitAsync(_ semaphore: DispatchSemaphore) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                semaphore.wait()
                continuation.resume()
            }
        }
    }

    /// Holds a real write transaction open on a second connection to the given
    /// file until told to let go, so a test can race something against it with
    /// no timing guesswork: `lockAcquired` only fires once the lock is
    /// genuinely held, `holderFinished` only fires once the transaction has
    /// actually closed.
    private func holdLock(
        onFile path: String,
        lockAcquired: DispatchSemaphore, releaseLock: DispatchSemaphore, holderFinished: DispatchSemaphore,
    ) {
        DispatchQueue.global().async {
            do {
                let contender = try DatabaseQueue(path: path)
                try contender.write { db in
                    try db.execute(sql: "CREATE TABLE IF NOT EXISTS lock_probe(x INTEGER)")
                    try db.execute(sql: "INSERT INTO lock_probe (x) VALUES (1)")
                    lockAcquired.signal()
                    releaseLock.wait()
                }
            } catch {
                lockAcquired.signal()
            }
            holderFinished.signal()
        }
    }

    /// Establishes that the harness creates real contention, and that GRDB's
    /// own default (`.immediateError`, unchanged for a bare `DatabaseQueue`)
    /// fails the way the bug report described — immediately, not after a wait.
    /// Without this, a passing test below would not distinguish "waited and
    /// succeeded" from "there was never any contention to begin with".
    @Test("a bare second connection with no configured busy mode fails immediately")
    func bareConnectionFailsImmediately() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let path = await store.url.path

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        holdLock(onFile: path, lockAcquired: lockAcquired, releaseLock: releaseLock, holderFinished: holderFinished)
        await waitAsync(lockAcquired)

        let bareConnection = try DatabaseQueue(path: path)
        #expect(throws: (any Error).self, "GRDB's default busyMode is .immediateError") {
            try bareConnection.write { db in
                try db.execute(sql: "CREATE TABLE IF NOT EXISTS other(x INTEGER)")
            }
        }

        releaseLock.signal()
        await waitAsync(holderFinished)
    }

    /// The fix. Without `MutationQueue.init` configuring a busy timeout, this
    /// is exactly the call above, on exactly the same file, and it throws the
    /// same way — silently, because every caller wraps `enqueue` in `try?`.
    @Test("MutationQueue waits out the same contention instead of failing immediately")
    func mutationQueueWaitsRatherThanFailing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)
        let path = await store.url.path

        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holderFinished = DispatchSemaphore(value: 0)
        holdLock(onFile: path, lockAcquired: lockAcquired, releaseLock: releaseLock, holderFinished: holderFinished)
        await waitAsync(lockAcquired)

        // Released from a timer well inside the 5s timeout, so the write below
        // must sit and wait for it rather than failing outright.
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            releaseLock.signal()
        }

        let recorded = try await queue.enqueue(.status, bookUUID: "x", payload: Data("{}".utf8))
        #expect(recorded)
        let pending = try await queue.pending()
        #expect(pending.count == 1, "the write must have actually reached the database, not merely not thrown")

        await waitAsync(holderFinished)
    }
}
