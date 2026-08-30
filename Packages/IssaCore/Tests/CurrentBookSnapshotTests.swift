import Foundation
import Testing

@testable import IssaCore

/// The record the app writes and the widget draws.
///
/// Both halves matter: the widget is a separate process that can be running
/// against a file an older build left behind, and the line under the title is
/// assembled from fields that are routinely absent or misleading.
@Suite("The widget's snapshot")
struct CurrentBookSnapshotTests {
    private func snapshot(
        title: String = "Piranesi", author: String = "Susanna Clarke",
        chapter: String? = nil, remaining: TimeInterval? = nil,
    ) -> CurrentBookSnapshot {
        CurrentBookSnapshot(
            bookID: "u", title: title, author: author, chapter: chapter,
            progress: 0.42, remaining: remaining)
    }

    // MARK: - The subtitle

    @Test("both halves, when both are known")
    func timeAndChapter() {
        #expect(snapshot(chapter: "Part 3", remaining: 8280).subtitle == "2h 18m left · Part 3")
    }

    /// `chapterTitle` returns the book's own title whenever no navigation entry
    /// matches the spine document, which is every plain EPUB.
    @Test("a chapter that is only the title again is not a chapter")
    func chapterEqualToTitleIsDropped() {
        #expect(snapshot(chapter: "Piranesi", remaining: 8280).subtitle == "2h 18m left")
    }

    /// A table-of-contents anchor with no text yields an empty title, which
    /// left a trailing separator on screen.
    @Test("an empty chapter leaves no dangling separator")
    func emptyChapterIsDropped() {
        #expect(snapshot(chapter: "   ", remaining: 8280).subtitle == "2h 18m left")
        #expect(!snapshot(chapter: "", remaining: 8280).subtitle.hasSuffix("· "))
    }

    /// The fallback that was unreachable: a plain ebook has no narration, and
    /// its chapter is usually the title, so without this the line was empty.
    @Test("a book with neither falls back to the author")
    func fallsBackToAuthor() {
        #expect(snapshot(chapter: "Piranesi").subtitle == "Susanna Clarke")
        #expect(snapshot().subtitle == "Susanna Clarke")
    }

    @Test("under an hour drops the hours")
    func minutesOnly() {
        #expect(snapshot(remaining: 900).subtitle == "15m left")
    }

    /// `durationText` floors, so anything under a minute rendered as "0m left"
    /// — for the whole final minute of every audiobook.
    @Test("less than a minute left is not reported as 0m")
    func subMinuteIsNotZeroMinutes() {
        for seconds in [0.0, 20, 45, 59.4] {
            let line = snapshot(chapter: "Part 3", remaining: seconds).subtitle
            #expect(!line.contains("0m"), "\(seconds)s rendered as \(line)")
            #expect(line == "Part 3")
        }
        // A full minute is worth saying.
        #expect(snapshot(chapter: "Part 3", remaining: 60).subtitle == "1m left · Part 3")
    }

    /// Every surface reads the same number. They disagreed: the ring rounded
    /// and the bar truncated, so at 99.6% two widgets showed 100% and 99% at
    /// the same instant.
    @Test("the percentage is rounded, once, for everything")
    func percentIsRounded() {
        #expect(CurrentBookSnapshot(bookID: "u", title: "T", author: "A", progress: 0.996).percent == 100)
        #expect(CurrentBookSnapshot(bookID: "u", title: "T", author: "A", progress: 0.994).percent == 99)
    }

    // MARK: - Whose cover is on disk

    /// The cover is one shared file written after the snapshot, so between the
    /// two writes it holds the previous book's jacket.
    @Test("a cover belonging to another book is not this book's")
    func coverIdentityIsChecked() {
        var subject = snapshot()
        #expect(!subject.hasMatchingCover)      // nothing claimed yet
        subject.coverBookID = "someone-else"
        #expect(!subject.hasMatchingCover)
        subject.coverBookID = subject.bookID
        #expect(subject.hasMatchingCover)
    }

    @Test("a snapshot from a build without cover identity still decodes")
    func decodesWithoutCoverIdentity() throws {
        let json = #"{"bookID":"u","title":"T","author":"A","progress":0.5}"#
        let restored = try JSONDecoder().decode(CurrentBookSnapshot.self, from: Data(json.utf8))
        #expect(restored.coverBookID == nil)
        #expect(!restored.hasMatchingCover)     // so the widget draws no stale art
    }

    // MARK: - Reading what an older build wrote

    @Test("a snapshot from a build without the cover shape still decodes")
    func decodesWithoutCoverShape() throws {
        let json = #"{"bookID":"u","title":"T","author":"A","progress":0.5,"isPlaying":true}"#
        let restored = try JSONDecoder().decode(CurrentBookSnapshot.self, from: Data(json.utf8))

        #expect(restored.title == "T")
        #expect(restored.progress == 0.5)
        #expect(restored.isPlaying)
        #expect(!restored.coverIsSquare)   // the default, not a decode failure
    }

    @Test("what it writes, it can read back")
    func roundTrips() throws {
        var original = snapshot(chapter: "Part 3", remaining: 8280)
        original.coverIsSquare = true
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(CurrentBookSnapshot.self, from: data)
        #expect(restored == original)
    }
}
