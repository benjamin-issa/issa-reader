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
