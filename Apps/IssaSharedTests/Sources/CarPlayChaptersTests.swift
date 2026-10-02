import Foundation
import Testing

@testable import IssaReader_iOS

/// Which of CarPlay's Up Next rows is the one being read.
///
/// The rows are one per nav point, and a Gutenberg-style book packs four
/// chapters into each file, told apart only by fragment. Matching the reader's
/// spine index marked the file's first chapter whichever of the four was being
/// narrated.
@Suite("CarPlay's current chapter")
struct CarPlayChaptersTests {
    /// Two files: the first holds chapters 1–4 at fragments laid out at
    /// 0, 1000, 2000 and 3000; the second is one chapter on its own.
    private static let entries: [CarPlayChapters.Entry] = [
        .init(spineIndex: 2, fragment: "ch1", title: "Chapter 1"),
        .init(spineIndex: 2, fragment: "ch2", title: "Chapter 2"),
        .init(spineIndex: 2, fragment: "ch3", title: "Chapter 3"),
        .init(spineIndex: 2, fragment: "ch4", title: "Chapter 4"),
        .init(spineIndex: 3, fragment: nil, title: "Chapter 5"),
    ]
    private static let laidOut = ["ch1": 0, "ch2": 1000, "ch3": 2000, "ch4": 3000]

    private static func current(spine: Int, offset: Int, layout: [String: Int] = laidOut) -> Int? {
        CarPlayChapters.currentIndex(in: entries, spineIndex: spine, offset: offset) { layout[$0] }
    }

    @Test("the third chapter of a four-chapter file is the third row, not the first")
    func chapterWithinAFile() {
        #expect(Self.current(spine: 2, offset: 2400) == 2)
        #expect(Self.current(spine: 2, offset: 3000) == 3, "a page that starts on a chapter is that chapter's")
        #expect(Self.current(spine: 2, offset: 999) == 0)
    }

    @Test("a file of its own is its own row")
    func wholeFile() {
        #expect(Self.current(spine: 3, offset: 50_000) == 4)
    }

    @Test("a file that is not laid out, or a spine item with no row, falls back sensibly")
    func fallbacks() {
        #expect(Self.current(spine: 2, offset: 2400, layout: [:]) == 0,
                "with nothing to compare against, the file's first row is the best answer")
        #expect(Self.current(spine: 7, offset: 0) == nil, "a spine item no row names has no current row")
    }
}
