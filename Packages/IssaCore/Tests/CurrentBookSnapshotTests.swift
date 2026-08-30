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
