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
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
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
        // A real claim first, so there is a state for a late callback to
        // corrupt — asserting on a job that was never started passed even
        // with `shutDown()` deleted outright.
        await subject.start(job)
        #expect(subject.state(for: job) == .queued)

        await subject.shutDown()

        // Late delegate callbacks from the superseded session — progress, a
        // finished file, the daemon reporting the transfer it killed. None
        // may be published: two managers sharing a background identifier is
        // what cancelled transfers in the first place.
        let task = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        task.taskDescription = DownloadManager.encode(job)
        subject.urlSession(
            URLSession.shared, downloadTask: task,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        subject.urlSession(
            URLSession.shared, downloadTask: task,
            didFinishDownloadingTo: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        subject.urlSession(
            URLSession.shared, task: task,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost))
        // The delegate writes state through hops to the main actor; let any
        // enqueued hop land before asserting that none of them wrote.
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(subject.state(for: job) == .queued,
                "a shut-down manager must not overwrite state with late callbacks")
    }

    /// The X on a failed row calls `cancel(_:)` with no live task — and no
    /// task means no delegate callback will ever come to consume whatever
    /// marker `cancel` leaves behind. A stale pause marker made the *next*
    /// download of the same job swallow a system-initiated cancellation as a
    /// pause, freezing the row at "downloading" with every control dead.
    @Test("cancelling a dead job does not eat the next download's interruption")
    func cancelOfDeadJobLeavesNoPauseMarker() async {
        let subject = manager()
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        // Dismiss a job with no live task, then download the same book again.
        subject.cancel(job)
        await subject.start(job)
        #expect(subject.hasTask(for: job))

        // The daemon reclaims the transfer: a cancellation nobody asked for.
        // Stamped as the manager would stamp the task it just started, or the
        // fence below would discard it as a straggler from before the cancel
        // and this test would pass without touching the marker at all.
        let task = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        task.taskDescription = subject.liveTaskDescription(for: job)
        subject.urlSession(
            URLSession.shared, task: task,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        for _ in 0 ..< 5 { await Task.yield() }

        #expect(subject.state(for: job)?.isFailure == true,
                "an unrequested cancellation must surface as a failure, not vanish into a stale pause marker")
        await subject.shutDown()
    }

    /// Sign-out calls `stop()`, not `shutDown()`, and then deletes the Books
    /// folder. The callbacks the cancel provokes arrive afterwards: a transfer
    /// that finished as the cancel landed used to re-create the folder and
    /// move the signed-out account's book back into it, and the cancellation
    /// itself wrote a `.failed` row into the state `stop()` had just emptied.
    @Test("a stopped manager ignores the callbacks its own cancel provokes")
    func stopSilencesLateCallbacks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "issa-stop-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = DownloadManager(
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { job in books.appending(path: "\(job.bookUUID).epub") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await subject.start(job)
        #expect(subject.hasTask(for: job))

        subject.stop()
        #expect(subject.state(for: job) == nil)

        // A file that landed just as the cancel did, then the cancellation.
        let source = root.appending(path: "arrived.tmp")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("book".utf8).write(to: source)
        let task = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        task.taskDescription = DownloadManager.encode(job)
        subject.urlSession(
            URLSession.shared, downloadTask: task,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        subject.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: source)
        subject.urlSession(
            URLSession.shared, task: task,
            didCompleteWithError: NSError(
                domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                userInfo: [NSURLSessionDownloadTaskResumeData: Data("resume".utf8)]))
        for _ in 0 ..< 5 { await Task.yield() }

        #expect(!FileManager.default.fileExists(atPath: books.path),
                "the deleted Books folder must not come back for the account that left")
        #expect(subject.state(for: job) == nil, "no phantom Retry row for the next account")
        #expect(subject.pending.isEmpty)

        // The same job downloaded again by the next account is a new transfer,
        // whose callbacks count — and the old transfer's, arriving late, still
        // do not: the two are told apart by the stamp, not by the job.
        await subject.start(job)
        #expect(subject.state(for: job) == .queued)
        subject.urlSession(
            URLSession.shared, task: task,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        let fresh = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        fresh.taskDescription = DownloadManager.encode(job, generation: 1)
        subject.urlSession(
            URLSession.shared, downloadTask: fresh,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(subject.state(for: job)?.isActive == true)
        await subject.shutDown()
    }

    /// The bug behind "I deleted it and it came back".
    ///
    /// `clear` forgets the state row and nothing else — the row leaves the
    /// screen, the transfer carries on, and when it lands
    /// `didFinishDownloadingTo` moves the file into place over the deletion.
    /// `AppModel.removeDownload` called `clear`, so removing a download that
    /// was still arriving deleted a file that had not finished being written
    /// and got it back a minute later. Cancel, then clear.
    @Test("clearing a transfer forgets its row; only cancelling stops it")
    func clearIsNotCancel() async {
        let subject = manager()
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        await subject.start(job)
        #expect(subject.hasTask(for: job))

        subject.clear(job)
        #expect(subject.state(for: job) == nil, "the row has left the screen")
        #expect(subject.hasTask(for: job), "and the transfer behind it has not")

        subject.cancel(job)
        #expect(!subject.hasTask(for: job), "this is the call that stops a download")
        #expect(subject.state(for: job) == nil)
        await subject.shutDown()
    }

    /// The residual half of "stop a deleted download coming back".
    ///
    /// `stop()` advances the fence and `cancel(_:)` did not, so a completion
    /// callback already in flight when a single cancel landed still passed it:
    /// `didFinishDownloadingTo` moves the file into place *before* it hops to
    /// the actor — it has to, the temporary file is deleted the moment it
    /// returns — so the file arrived in the directory the removal had just
    /// emptied, and `onFinished` put the book back on the shelf. The reader
    /// deleted a download and watched it reappear.
    ///
    /// Asserted on the file and on `onFinished`, because those are the two
    /// things that actually reached the reader; the state row was already
    /// cleared by `cancel` and would have looked right either way.
    @Test("a completion already in flight cannot land after its job was cancelled")
    func cancelFencesTheCompletionInFlight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "issa-cancel-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = DownloadManager(
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { job in books.appending(path: "\(job.bookUUID).epub") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        await subject.start(job)
        // The stamp the real task carries — taken before the cancel, which is
        // exactly the position a callback already in flight is in.
        let inFlight = subject.liveTaskDescription(for: job)

        var finished: [DownloadManager.Job] = []
        subject.onFinished = { finished.append($0) }

        subject.cancel(job)

        let arrived = root.appending(path: "arrived.tmp")
        try Data("book".utf8).write(to: arrived)
        let task = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        task.taskDescription = inFlight
        subject.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: arrived)
        for _ in 0 ..< 5 { await Task.yield() }

        #expect(!FileManager.default.fileExists(atPath: books.path),
                "the cancelled transfer moved its file into place anyway")
        #expect(finished.isEmpty, "onFinished would have put the book back on the shelf")
        #expect(subject.state(for: job) == nil, "no row for a transfer the reader stopped")
        await subject.shutDown()
    }

    /// One cancel must not strand every other transfer. The fence is per job
    /// precisely because the global number is what all the live tasks carry —
    /// advancing that here would leave each of them unable to finish, with its
    /// row stuck at "downloading" and its file never moved into place.
    @Test("cancelling one download leaves the others' callbacks live")
    func cancelDoesNotFenceOtherJobs() async {
        let subject = manager()
        let cancelled = DownloadManager.Job(bookUUID: "b", format: .ebook)
        let other = DownloadManager.Job(bookUUID: "c", format: .readaloud)
        await subject.start(cancelled)
        await subject.start(other)
        let othersStamp = subject.liveTaskDescription(for: other)

        subject.cancel(cancelled)

        let task = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        task.taskDescription = othersStamp
        subject.urlSession(
            URLSession.shared, downloadTask: task,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        for _ in 0 ..< 5 { await Task.yield() }

        #expect(subject.state(for: other)?.isActive == true,
                "the other transfer was fenced out by a cancel that was not its own")
        await subject.shutDown()
    }

    /// A restart of the same job takes the new number, so the transfer the
    /// reader asked for is live while the one they cancelled is not. This is
    /// why the fence is a counter rather than a set of cancelled jobs.
    @Test("restarting a cancelled job makes its own callbacks live again")
    func restartingAfterCancelIsLive() async {
        let subject = manager()
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await subject.start(job)
        let stale = subject.liveTaskDescription(for: job)

        subject.cancel(job)
        await subject.start(job)
        let fresh = subject.liveTaskDescription(for: job)
        #expect(stale != fresh, "the two transfers have to be tellable apart")

        let old = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        old.taskDescription = stale
        subject.urlSession(
            URLSession.shared, downloadTask: old,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(subject.state(for: job) == .queued, "the cancelled transfer still reported progress")

        let new = URLSession.shared.downloadTask(with: URL(string: "http://example.test/file")!)
        new.taskDescription = fresh
        subject.urlSession(
            URLSession.shared, downloadTask: new,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(subject.state(for: job)?.isActive == true)
        await subject.shutDown()
    }

    @Test("a stamped task description still decodes to its job")
    func stampedDescriptionsDecode() {
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        let stamped = DownloadManager.encode(job, generation: 7)
        #expect(DownloadManager.decode(stamped) == job)
        #expect(DownloadManager.decodeStamped(stamped)?.generation == 7)
        #expect(DownloadManager.decodeStamped(stamped)?.epoch == 0)
        #expect(DownloadManager.decodeStamped(DownloadManager.encode(job))?.generation == 0)
        #expect(DownloadManager.decode("b|readaloud|x") == nil)

        // Both numbers, and a description from a build that knew of neither.
        let fenced = DownloadManager.encode(job, generation: 7, epoch: 3)
        #expect(DownloadManager.decode(fenced) == job)
        #expect(DownloadManager.decodeStamped(fenced)?.generation == 7)
        #expect(DownloadManager.decodeStamped(fenced)?.epoch == 3)
        #expect(DownloadManager.decodeStamped("b|readaloud")?.epoch == 0,
                "a task started by an older build still has to be reattachable")
        #expect(DownloadManager.decode("b|readaloud|1|x") == nil)
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
            baseURL: unreachableServer,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
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
        await manager.shutDown()
    }

    /// A session invalidated during the same window is worse than a cancel:
    /// `downloadTask(with:)` on an invalid session does not fail, it raises an
    /// `NSGenericException`, and nothing in Swift can catch that. Sign-out
    /// lands in this window whenever a download is starting, and a reconnect
    /// used to as well.
    @Test("a shutdown that lands before the task exists fails the job instead of raising")
    func shutDownDuringTokenFetchDoesNotCreateATask() async {
        let tokens = GatedTokens()
        let manager = DownloadManager(
            baseURL: unreachableServer,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        let starting = Task { await manager.start(job) }
        await tokens.waitUntilEntered()
        await manager.shutDown()
        await tokens.release()
        await starting.value

        #expect(!manager.hasTask(for: job), "no task may be created on an invalidated session")
        #expect(manager.state(for: job)?.isFailure == true,
                "the row must say why, not sit at queued forever")
    }

    /// Reconnecting re-points the one manager rather than replacing it, so the
    /// server and credential a request is built with are the new ones.
    @Test("reconfiguring a manager keeps it usable")
    func reconfigureKeepsTheManager() async {
        // Two addresses from the same unrouted documentation block, so the
        // real task this starts waits rather than failing under the test.
        let manager = DownloadManager(
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        manager.reconfigure(baseURL: URL(string: "http://192.0.2.2")!, tokens: StubTokens())
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await manager.start(job)
        #expect(manager.state(for: job) == .queued)
        #expect(manager.request(for: job)?.url?.host() == "192.0.2.2")
        await manager.shutDown()
    }

    /// Sign-out then sign-in, in one process.
    ///
    /// The account's transfers must go, but the session must not: the daemon
    /// keys a background session on its identifier for the whole process, and
    /// invalidating one here made the next one invalid from birth — its first
    /// `downloadTask(with:)` raised an `NSGenericException` no Swift code can
    /// catch, which is what took Build 16 down on launch.
    @Test("stopping for a sign-out leaves the manager able to download again")
    func stopThenReconfigureStillDownloads() async {
        let manager = DownloadManager(
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await manager.start(job)
        #expect(manager.hasTask(for: job))

        // Sign out: the transfer and its row go.
        manager.stop()
        #expect(!manager.hasTask(for: job))
        #expect(manager.state(for: job) == nil)
        #expect(manager.pending.isEmpty)

        // Sign in as someone else: same manager, same session, new server.
        manager.reconfigure(baseURL: URL(string: "http://192.0.2.2")!, tokens: StubTokens())
        await manager.start(job)
        #expect(manager.state(for: job) == .queued)
        #expect(manager.request(for: job)?.url?.host() == "192.0.2.2")
        await manager.shutDown()
    }

    /// The ordinary case, unchanged: a cancel with a real task in flight still
    /// goes through the task's own `cancel()`.
    @Test("a cancel after the task exists still cancels it directly")
    func cancelAfterTaskExistsIsUnaffected() async {
        let tokens = GatedTokens()
        let manager = DownloadManager(
            baseURL: unreachableServer,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        await tokens.release()
        await manager.start(job)
        #expect(manager.hasTask(for: job))

        manager.cancel(job)
        #expect(!manager.hasTask(for: job))
        #expect(manager.state(for: job) == nil)
        await manager.shutDown()
    }

    /// A cancel with no `start` ever having been called must not leave a
    /// phantom marker that poisons the *next* job to start.
    @Test("cancelling a job that never started does not affect a later start of it")
    func cancelWithoutStartLeavesNoResidue() async {
        let tokens = GatedTokens()
        await tokens.release()
        let manager = DownloadManager(
            baseURL: unreachableServer,
            tokens: tokens,
            identifier: "test.\(UUID().uuidString)",
            fenceStore: nil,
            destinationFor: { _ in URL(fileURLWithPath: "/dev/null") },
        )
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)

        manager.cancel(job)
        await manager.start(job)
        #expect(manager.hasTask(for: job), "a later, real start must not be swallowed by a stale cancel marker")
        await manager.shutDown()
    }
}

/// The fence across a relaunch.
///
/// A task's stamp is kept by the daemon, but the numbers it is checked against
/// lived only in the process: every launch began again at nothing, so a
/// transfer stamped after a sign-out or a cancel-and-restart in the last
/// process — and finished while the app was away — was thrown out the moment
/// the next launch heard of it. The file was deleted by the system, no row
/// appeared, and the book offered "Download" again.
@Suite("The download fence across a relaunch")
@MainActor
struct DownloadFenceTests {
    private func temporary() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "issa-fence-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func manager(books: URL, fenceStore: UserDefaults? = nil) -> DownloadManager {
        DownloadManager(
            baseURL: unreachableServer,
            tokens: StubTokens(),
            identifier: "test.\(UUID().uuidString)",
            fenceStore: fenceStore,
            destinationFor: { job in
                BookContentService.localURL(in: books, bookUUID: job.bookUUID, format: job.format)
            },
        )
    }

    /// Defaults of the test's own, standing for the app's across a relaunch.
    private func defaults() throws -> (UserDefaults, String) {
        let suite = "issa-fence-\(UUID().uuidString)"
        return (try #require(UserDefaults(suiteName: suite)), suite)
    }

    /// What the daemon replays as a session is built: a transfer that
    /// finished while the app was away, stamped as the given description.
    private func deliverFinished(
        _ description: String, to subject: DownloadManager, in root: URL,
    ) async throws {
        let task = await DownloadStubProtocol.finishedTask(.epub)
        task.taskDescription = description
        let arrived = try DownloadStubProtocol.arrivedFile(.epub, in: root)
        subject.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: arrived)
    }

    /// The fix itself. The last launch signed out and cancelled a download,
    /// and its fence was kept; this launch judges that launch's transfers by
    /// the same numbers — taking the ones started afterwards, and still
    /// refusing the ones those calls stopped.
    @Test("a fence kept by the last launch lets its transfers finish, and still refuses what it stopped")
    func aKeptFenceJudgesTheLastLaunchesTransfers() async throws {
        let root = temporary()
        let (store, suite) = try defaults()
        defer {
            store.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let restarted = DownloadManager.Job(bookUUID: "r", format: .ebook)

        // The last launch: a sign-out, then a download cancelled.
        let last = manager(books: books, fenceStore: store)
        last.stop()
        last.cancel(restarted)
        await last.shutDown()

        let subject = manager(books: books, fenceStore: store)
        var finished: [DownloadManager.Job] = []
        subject.onFinished = { finished.append($0) }
        let afterSignOut = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        let beforeSignOut = DownloadManager.Job(bookUUID: "c", format: .readaloud)

        // The stale ones first: let through, they would publish ahead of the
        // live ones, which is what the exact comparison below would catch.
        try await deliverFinished(DownloadManager.encode(beforeSignOut), to: subject, in: root)
        try await deliverFinished(
            DownloadManager.encode(restarted, generation: 1), to: subject, in: root)
        try await deliverFinished(
            DownloadManager.encode(afterSignOut, generation: 1), to: subject, in: root)
        try await deliverFinished(
            DownloadManager.encode(restarted, generation: 1, epoch: 1), to: subject, in: root)
        await settle { finished.count >= 2 }

        #expect(finished == [afterSignOut, restarted],
                "only the transfers started after the sign-out and the cancel are wanted")
        #expect(subject.state(for: afterSignOut) == .finished)
        #expect(subject.state(for: restarted) == .finished)
        #expect(subject.state(for: beforeSignOut) == nil, "the sign-out stopped this one")
        #expect(!FileManager.default.fileExists(
            atPath: BookContentService.localURL(in: books, bookUUID: "c", format: .readaloud).path))
        await subject.shutDown()
    }

    /// Written on every call that moves it, so a launch that ends without
    /// warning has already kept what the next one needs.
    @Test("every stop and cancel writes the fence down")
    func theFenceIsKeptAsItMoves() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let subject = manager(books: temporary(), fenceStore: store)
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        #expect(DownloadManager.loadFence(from: store) == nil, "nothing to keep before anything moved it")

        subject.cancel(job)
        #expect(DownloadManager.loadFence(from: store)
            == DownloadManager.Fence(global: 0, perJob: [job: 1], armed: true))
        subject.stop()
        #expect(DownloadManager.loadFence(from: store)
            == DownloadManager.Fence(global: 1, perJob: [:], armed: true))
        await subject.shutDown()
    }

    /// The finding's own trigger. A download removed before the daemon's list
    /// of transfers came back had no task here to stop, so `cancel` could only
    /// advance the fence — and reattaching then re-stamped the transfer with
    /// the advanced number and adopted it: tracked, shown as downloading, and
    /// moved into the place the removal had just emptied when it finished.
    @Test("a job cancelled before the system's transfers are reattached stays cancelled")
    func aCancelledJobIsNotAdoptedBack() async {
        let subject = manager(books: temporary())
        let cancelled = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        let untouched = DownloadManager.Job(bookUUID: "c", format: .ebook)
        subject.cancel(cancelled)

        let stale = URLSession.shared.downloadTask(with: unreachableServer.appending(path: "b"))
        stale.taskDescription = DownloadManager.encode(cancelled)
        let carried = URLSession.shared.downloadTask(with: unreachableServer.appending(path: "c"))
        carried.taskDescription = DownloadManager.encode(untouched)
        subject.adopt([stale, carried])

        #expect(!subject.hasTask(for: cancelled), "the cancelled job was adopted back into life")
        #expect(subject.state(for: cancelled) == nil)
        #expect(stale.state == .canceling || stale.state == .completed, "and its transfer has to stop")
        #expect(subject.hasTask(for: untouched), "a transfer nobody cancelled is still taken on")
        #expect(subject.state(for: untouched)?.isActive == true)
        await subject.shutDown()
    }

    /// Unarmed — the first launch after upgrading — nothing can be judged, so
    /// a transfer the system carried on with is re-stamped as this launch's
    /// own and adopted, and stays live once the fence arms for another job.
    @Test("unarmed, a transfer the system carried on with is taken on as this launch's own")
    func unarmedAdoptionRestamps() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = manager(books: books)
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)
        var finished: [DownloadManager.Job] = []
        subject.onFinished = { finished.append($0) }

        let carried = await DownloadStubProtocol.finishedTask(.epub)
        carried.taskDescription = DownloadManager.encode(job, generation: 4, epoch: 2)
        subject.adopt([carried])
        #expect(subject.hasTask(for: job))
        #expect(carried.taskDescription == DownloadManager.encode(job))

        subject.cancel(DownloadManager.Job(bookUUID: "other", format: .ebook))
        let arrived = try DownloadStubProtocol.arrivedFile(.epub, in: root)
        subject.urlSession(URLSession.shared, downloadTask: carried, didFinishDownloadingTo: arrived)
        await settle { !finished.isEmpty }

        #expect(finished == [job], "arming for another job stranded an adopted transfer")
        #expect(subject.state(for: job) == .finished)
        await subject.shutDown()
    }

    /// The first launch after upgrading from a build that kept no fence. It
    /// has no record of the numbers the last process reached, so it cannot
    /// tell a stale stamp from a live one — and throwing a finished book away
    /// is the worse of the two mistakes.
    @Test(
        "a transfer finished while the app was away is kept on the first launch after upgrading",
        arguments: [(1, 0), (0, 1), (3, 2)])
    func anUpgradeKeepsWhatFinishedWhileAway(generation: Int, epoch: Int) async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let books = root.appending(path: "Books", directoryHint: .isDirectory)
        let subject = manager(books: books)
        var finished: [DownloadManager.Job] = []
        subject.onFinished = { finished.append($0) }
        let job = DownloadManager.Job(bookUUID: "b", format: .readaloud)

        // What the daemon replays as the session is built: a transfer the last
        // process stamped after a sign-out, or after a cancel and a restart.
        let task = await DownloadStubProtocol.finishedTask(.epub)
        task.taskDescription = DownloadManager.encode(job, generation: generation, epoch: epoch)
        let arrived = try DownloadStubProtocol.arrivedFile(.epub, in: root)
        subject.urlSession(URLSession.shared, downloadTask: task, didFinishDownloadingTo: arrived)
        await settle { subject.state(for: job) != nil }

        #expect(subject.state(for: job) == .finished, "the finished transfer was thrown away")
        #expect(FileManager.default.fileExists(
            atPath: BookContentService.localURL(in: books, bookUUID: "b", format: .readaloud).path))
        #expect(finished == [job])
        await subject.shutDown()
    }

    /// `cancel` marked the job as pausing so its own cancellation would not
    /// read as a failure, and then advanced the job's epoch — which fences out
    /// exactly that cancellation, so nothing ever consumed the marker. The
    /// same job downloaded again then took the next cancellation it did not
    /// ask for — the system reclaiming the transfer — for a pause, and the row
    /// sat at "downloading" with no task behind it and every control dead.
    @Test("a download cancelled and started again still reports an interruption it did not ask for")
    func aRestartAfterCancelStillReportsInterruption() async {
        let subject = manager(books: temporary())
        let job = DownloadManager.Job(bookUUID: "b", format: .ebook)
        await subject.start(job)
        #expect(subject.hasTask(for: job), "the cancel has to find a live task")

        subject.cancel(job)
        await subject.start(job)
        let restarted = URLSession.shared.downloadTask(with: unreachableServer.appending(path: "file"))
        restarted.taskDescription = subject.liveTaskDescription(for: job)
        subject.urlSession(
            URLSession.shared, downloadTask: restarted,
            didWriteData: 512, totalBytesWritten: 512, totalBytesExpectedToWrite: 1_024)
        await settle { subject.state(for: job)?.fraction == 0.5 }
        #expect(subject.state(for: job)?.fraction == 0.5, "the restarted transfer is under way")

        // The system reclaims it: a cancellation nobody here asked for.
        subject.urlSession(
            URLSession.shared, task: restarted,
            didCompleteWithError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        await settle { subject.state(for: job)?.isFailure == true }

        #expect(subject.state(for: job)?.isFailure == true,
                "swallowed as a pause, the row stays at downloading with nothing behind it")
        #expect(!subject.hasTask(for: job))
        await subject.shutDown()
    }
}
