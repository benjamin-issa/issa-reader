import Foundation
import Testing

@testable import IssaCore

/// The single control the book screen offers.
///
/// Most of these are ordering questions, and ordering is where this kind of
/// state machine goes wrong quietly: the button still renders, it just says the
/// wrong thing about a book the reader can see.
@Suite("The book screen's primary control")
struct BookPrimaryActionTests {
    private func book(
        progress: Double? = nil,
        ebookSize: Int? = nil,
        ebookMissing: Bool? = nil,
        hasEbook: Bool = true,
        audiobookOnly: Bool = false,
    ) -> Book {
        var json: [String: Any] = [
            "uuid": "u", "title": "A Book",
            "authors": [], "narrators": [], "creators": [], "series": [],
            "collections": [], "identifiers": [], "tags": [],
        ]
        if audiobookOnly {
            json["audiobook"] = ["uuid": "a", "filepath": "a.m4b", "identifiers": []]
        } else if hasEbook {
            var ebook: [String: Any] = ["uuid": "e", "identifiers": []]
            if let ebookSize { ebook["fileSize"] = ebookSize }
            if let ebookMissing { ebook["missing"] = ebookMissing }
            json["ebook"] = ebook
        }
        if let progress {
            json["position"] = [
                "locator": ["href": "a", "type": "t", "locations": ["totalProgression": progress]],
                "timestamp": 0,
            ]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(Book.self, from: data)
    }

    private func action(
        _ subject: Book, state: DownloadManager.State? = nil, isDownloaded: Bool = false,
    ) -> BookPrimaryAction? {
        BookPrimaryAction.resolve(book: subject, state: state, isDownloaded: isDownloaded)
    }

    // MARK: - The gate

    @Test("a book with nothing readable gets no control at all, rather than a dead end")
    func audiobookOnlyGetsNoControl() {
        #expect(action(book(audiobookOnly: true)) == nil)
    }

    @Test("a book whose only edition the server has lost gets no control")
    func missingEbookGetsNoControl() {
        #expect(action(book(ebookMissing: true)) == nil)
    }

    // MARK: - Labels

    @Test("a book that is not here offers to fetch it, and says how big it is")
    func notDownloadedOffersDownload() throws {
        let subject = try #require(action(book(ebookSize: 312_000_000)))
        #expect(subject.title().hasPrefix("Download · "))
        #expect(subject.intent == .startDownload)
    }

    @Test("a size the server did not give is simply not claimed")
    func unknownSizeIsNotInvented() throws {
        let subject = try #require(action(book()))
        #expect(subject.title() == "Download")
    }

    @Test("a transfer in flight shows its percentage")
    func downloadingShowsPercent() throws {
        let state = DownloadManager.State.downloading(
            fractionCompleted: 0.64, bytesWritten: 64, totalBytes: 100)
        let subject = try #require(action(book(), state: state))
        #expect(subject.title() == "64%")
        #expect(subject.isDeterminate)
        #expect(subject.intent == .pauseDownload)
    }

    /// A fraction of zero is also what a stalled transfer looks like, so an
    /// unknown total must not borrow the same face.
    @Test("a download of unknown size never reads as 0%")
    func indeterminateDownloadIsNotZeroPercent() throws {
        let state = DownloadManager.State.downloading(
            fractionCompleted: 0, bytesWritten: 5_000_000, totalBytes: 0)
        let subject = try #require(action(book(), state: state))
        #expect(subject.title() != "0%")
        #expect(!subject.isDeterminate)
    }

    @Test("a queued download says it is waiting, not that it is at zero")
    func queuedSaysWaiting() throws {
        let subject = try #require(action(book(), state: .queued))
        #expect(subject.title() == "Waiting…")
        #expect(!subject.isDeterminate)
        #expect(subject.intent == .pauseDownload)
    }

    /// The collision this guards: "Resume" is already the reading action in
    /// this very button, so a paused download must not borrow the word.
    @Test("a paused download never says Resume")
    func pausedNeverSaysResume() throws {
        let subject = try #require(action(book(), state: .paused(fractionCompleted: 0.64)))
        #expect(subject.title() == "Paused · 64%")
        #expect(!subject.title().contains("Resume"))
        #expect(subject.intent == .resumeDownload)
    }

    @Test("a book on the device that was never opened says Read")
    func downloadedUnopenedSaysRead() throws {
        let subject = try #require(action(book(), isDownloaded: true))
        #expect(subject.title() == "Read")
        #expect(subject.intent == .openReader)
    }

    @Test("a book with somewhere to return to says where")
    func downloadedWithProgressSaysResume() throws {
        let subject = try #require(action(book(progress: 0.42), isDownloaded: true))
        #expect(subject.title() == "Resume · 42%")
    }

    @Test("a percentage that would round to nothing is left off")
    func barelyStartedDropsThePercentage() throws {
        let subject = try #require(action(book(progress: 0.004), isDownloaded: true))
        #expect(subject.title() == "Resume")
    }

    @Test("a failure offers to try again, and says why on screen")
    func failureShowsItsReason() throws {
        let subject = try #require(action(book(), state: .failed("The server returned 404.")))
        #expect(subject.title() == "Retry")
        #expect(subject.detail == "The server returned 404.")
        #expect(subject.intent == .startDownload)
    }

    // MARK: - Precedence, which is where this goes wrong

    /// A non-2xx never touches the destination file, so a book that downloaded
    /// cleanly and later failed a re-download has both a good file and a failed
    /// state. Offering "Retry" over a readable book would be wrong.
    @Test("a readable book on disk beats a stale failure")
    func onDiskBeatsFailed() throws {
        let subject = try #require(
            action(book(progress: 0.5), state: .failed("nope"), isDownloaded: true))
        #expect(subject.title() == "Resume · 50%")
        #expect(subject.detail == nil)
    }

    @Test("a transfer in flight beats an older copy on disk")
    func downloadingBeatsOnDisk() throws {
        let state = DownloadManager.State.downloading(
            fractionCompleted: 0.3, bytesWritten: 3, totalBytes: 10)
        let subject = try #require(action(book(), state: state, isDownloaded: true))
        #expect(subject.title() == "30%")
    }

    /// Deleted from the downloads screen while this screen was open.
    @Test("a finished download whose file has gone offers to fetch it again")
    func finishedButDeletedOffersDownload() throws {
        let subject = try #require(action(book(), state: .finished, isDownloaded: false))
        #expect(subject.title() == "Download")
    }

    @Test("the compact label drops every suffix, for accessibility text sizes")
    func compactDropsSuffixes() throws {
        #expect(try #require(action(book(ebookSize: 312_000_000))).title(compact: true) == "Download")
        #expect(try #require(action(book(progress: 0.42), isDownloaded: true))
            .title(compact: true) == "Resume")
        #expect(try #require(action(book(), state: .paused(fractionCompleted: 0.6)))
            .title(compact: true) == "Paused")
    }
}

@Suite("What an edition row says")
struct DownloadStatusTextTests {
    @Test("a size the server did not give shows bytes, not a percentage")
    func unknownTotalShowsBytes() {
        let state = DownloadManager.State.downloading(
            fractionCompleted: 0, bytesWritten: 5_000_000, totalBytes: 0)
        #expect(DownloadStatusText.short(state, isDownloaded: false) != "0%")
    }

    @Test("a row with no state says whether the file is there")
    func noStateReportsDisk() {
        #expect(DownloadStatusText.short(nil, isDownloaded: true) == "Downloaded")
        #expect(DownloadStatusText.short(nil, isDownloaded: false) == "Not downloaded")
    }
}
