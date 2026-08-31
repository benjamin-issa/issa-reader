import Foundation
import Testing

@testable import IssaCore

@Suite("Downloads")
struct DownloadManagerTests {
    @Test("A job survives the round trip through a task description")
    func jobRoundTrip() {
        for format in [BookContentService.Format.ebook, .audiobook, .readaloud] {
            let job = DownloadManager.Job(bookUUID: "0198f1c2-6f5a-7000-8000-abcdef012345", format: format)
            let decoded = DownloadManager.decode(DownloadManager.encode(job))
            #expect(decoded == job)
        }
    }

    /// The task description is the only thing that identifies a transfer after a
    /// relaunch, so a malformed one must not be guessed at.
    @Test("Nonsense task descriptions decode to nothing")
    func rejectsGarbage() {
        #expect(DownloadManager.decode("") == nil)
        #expect(DownloadManager.decode("no-separator") == nil)
        #expect(DownloadManager.decode("uuid|nonsense-format") == nil)
        #expect(DownloadManager.decode("a|b|c") == nil)
    }

    @Test("A download larger than the disk is refused before it starts")
    func refusesImpossibleDownload() {
        #expect(DownloadManager.hasRoom(for: 1_000))
        // Larger than any Mac or phone this will run on.
        #expect(!DownloadManager.hasRoom(for: 500_000_000_000_000))
    }

    @Test("Progress reads the same whichever state it came from")
    func fractions() {
        #expect(DownloadManager.State.queued.fraction == 0)
        #expect(DownloadManager.State.finished.fraction == 1)
        #expect(DownloadManager.State.paused(fractionCompleted: 0.4).fraction == 0.4)
        #expect(DownloadManager.State.downloading(
            fractionCompleted: 0.25, bytesWritten: 25, totalBytes: 100).fraction == 0.25)
        #expect(DownloadManager.State.failed("no").isFailure)
        #expect(!DownloadManager.State.failed("no").isActive)
        #expect(DownloadManager.State.queued.isActive)
    }
}

/// The states a transfer can be left in.
///
/// The bug these cover: a cancellation the app did not ask for used to be
/// ignored, because the only cancellation the code expected was a pause. That
/// left the row reading "downloading" forever with every control on it dead —
/// `start` early-returns while `isActive`, and `pause` early-returns because
/// the task handle is already gone.
@Suite("A download that is interrupted")
@MainActor
struct DownloadInterruptionTests {
    func manager() -> DownloadManager {
        DownloadManager(
            baseURL: URL(string: "http://example.test")!,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
    }

    @Test("an active download blocks a second start, which is why a stuck state is fatal")
    func activeBlocksStart() {
        let state = DownloadManager.State.downloading(
            fractionCompleted: 0.5, bytesWritten: 5, totalBytes: 10)
        #expect(state.isActive)
        // `start` guards on isActive, so anything that leaves a job in this
        // state with no live task can never be restarted by the user.
        #expect(DownloadManager.State.queued.isActive)
        #expect(!DownloadManager.State.paused(fractionCompleted: 0.5).isActive)
        #expect(!DownloadManager.State.failed("x").isActive)
        #expect(!DownloadManager.State.finished.isActive)
    }

    /// A response with no Content-Length reports -1, so a fraction of 0 is
    /// indistinguishable from a stall. It has to be flagged as indeterminate.
    @Test("an unknown total is indeterminate, not zero percent")
    func unknownTotal() {
        let unknown = DownloadManager.State.downloading(
            fractionCompleted: 0, bytesWritten: 4_096, totalBytes: -1)
        #expect(unknown.isIndeterminate)
        #expect(unknown.fraction == 0)

        let known = DownloadManager.State.downloading(
            fractionCompleted: 0.25, bytesWritten: 25, totalBytes: 100)
        #expect(!known.isIndeterminate)
        #expect(!DownloadManager.State.queued.isIndeterminate)
        #expect(!DownloadManager.State.finished.isIndeterminate)
    }

    @Test("shutting a manager down stops it writing state")
    func shutDownSilencesIt() async {
        let subject = manager()
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await subject.shutDown()
        // A superseded manager must not publish anything: two managers sharing
        // a background identifier is what cancelled transfers in the first place.
        #expect(subject.state(for: job) == nil)
    }
}

/// What a failure says, now that it is drawn on screen rather than living in
/// an accessibility label.
@Suite("Reporting a failed download")
struct DownloadReasonTests {
    @Test("a server's own explanation is passed through")
    func realReasonSurvives() {
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "The request timed out."])
        #expect(DownloadManager.readableReason(for: error) == "The request timed out.")
    }

    @Test("the system's \"unknown error\" is replaced with something actionable")
    func unknownBecomesActionable() {
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorUnknown,
            userInfo: [NSLocalizedDescriptionKey: "unknown error"])
        let reason = DownloadManager.readableReason(for: error)
        #expect(!reason.lowercased().contains("unknown error"))
        #expect(reason.contains("try again"))
    }
}

private struct StubTokens: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}


/// `cancel(_:)` arriving while `start(_:)` is still awaiting a token, with no
/// task yet in existence to cancel.
///
/// `TokenProviding.currentToken()` is the only await point between "claim the
/// job" and "create and resume the task", so a gate on it is what makes the
/// race deterministic instead of a timing guess.
private actor GatedTokens: TokenProviding {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var didEnter = false
    private var released = false

    func currentToken() async -> String? {
        didEnter = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        if !released {
            await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
                releaseContinuation = k
            }
        }
        return "test-token"
    }

    /// Suspends until `currentToken()` has been entered — i.e. until `start(_:)`
    /// is genuinely inside its one await point, so the race is real rather than
    /// assumed.
    func waitUntilEntered() async {
        guard !didEnter else { return }
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            enteredContinuation = k
        }
    }

    func release() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func invalidate() async {}
}

@Suite("Cancelling before a download's task exists")
@MainActor
struct CancelBeforeStartTests {
    /// The regression this exists for. `cancel(_:)` had nothing to act on
    /// during this window — `tasks[job]` was nil — so it silently did nothing:
    /// `start(_:)` resumed once the token arrived, created the task, and
    /// resumed it regardless. The transfer then completed, moved its file into
    /// place and fired `onFinished` for a download the caller had already
    /// asked to stop.
    @Test("a cancel that lands before the task exists is honoured once it would")
    func cancelDuringTokenFetchStopsTheTask() async {
        let tokens = GatedTokens()
        let manager = DownloadManager(
            baseURL: URL(string: "http://example.test")!,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        let starting = Task { await manager.start(job) }
        await tokens.waitUntilEntered()
        // `start(_:)` is now genuinely suspended inside `currentToken()` —
        // exactly the window the bug lived in.
        #expect(manager.state(for: job) == .queued)

        manager.cancel(job)
        #expect(manager.state(for: job) == nil, "cancel should clear the state immediately")

        await tokens.release()
        await starting.value

        #expect(!manager.hasTask(for: job),
                "the task must never be created for a job already cancelled")
        #expect(manager.state(for: job) == nil,
                "start resuming after the cancel must not resurrect the job")
    }

    /// The ordinary case, unchanged: a cancel with a real task in flight still
    /// goes through the task's own `cancel()`.
    @Test("a cancel after the task exists still cancels it directly")
    func cancelAfterTaskExistsIsUnaffected() async {
        let tokens = GatedTokens()
        let manager = DownloadManager(
            baseURL: URL(string: "http://example.test")!,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        await tokens.release()
        await manager.start(job)
        #expect(manager.hasTask(for: job))

        manager.cancel(job)
        #expect(!manager.hasTask(for: job))
        #expect(manager.state(for: job) == nil)
    }

    /// A cancel with no `start` ever having been called must not leave a
    /// phantom marker that poisons the *next* job to start.
    @Test("cancelling a job that never started does not affect a later start of it")
    func cancelWithoutStartLeavesNoResidue() async {
        let tokens = GatedTokens()
        await tokens.release()
        let manager = DownloadManager(
            baseURL: URL(string: "http://example.test")!,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        manager.cancel(job)
        await manager.start(job)
        #expect(manager.hasTask(for: job), "a later, real start must not be swallowed by a stale cancel marker")
    }
}
