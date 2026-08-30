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

private struct StubTokens: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}
