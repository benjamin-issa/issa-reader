import Foundation
import Testing

@testable import IssaReader_iOS

/// How far a page turn may drag the voice.
///
/// `firstNarratedFragment(beginningOn:)` fell back to enumerating fragment ids
/// from the top of the page to the **end of the chapter**, with no limit at
/// all, and `turnPage(forward:)` and `playFromVisiblePage()` both rest on it.
/// `TVReaderStyle` forces `followNarration` on, because on a television the
/// page is the only scrubber there is — so one press of ▶ on a plate or a
/// chapter opening seeked to a sentence pages ahead and took the page with it,
/// past everything the reader had not read yet.
@Suite("How far narration may be looked for")
struct NarrationReachTests {
    /// A page of 400 characters at offset 1,000, in a chapter of 10,000.
    private static let pageTop = 1_000
    private static let pageLength = 400
    private static let chapter = 10_000

    @Test("the reach is the page in hand and the one after it")
    func reachIsTwoPages() throws {
        let range = try #require(NarrationReach.range(
            fromPageTop: Self.pageTop, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ))
        #expect(range.location == Self.pageTop)
        #expect(range.length == Self.pageLength * 2)
        // The regression, stated as a number: the whole rest of the chapter is
        // 9,000 characters, and that is what this used to walk.
        #expect(range.length < Self.chapter - Self.pageTop)
    }

    /// Two pages of a phone at 14 pt and two pages of a television at 40 pt are
    /// different numbers of characters, and both are two pages. Deriving the
    /// reach from the page in hand is what makes the promise the same one.
    @Test("the reach is measured in this book's own pages, not the book's length")
    func reachFollowsThePageSize() throws {
        let television = try #require(NarrationReach.range(
            fromPageTop: 0, pageLength: 300, inTextOfLength: Self.chapter,
        ))
        let phone = try #require(NarrationReach.range(
            fromPageTop: 0, pageLength: 1_200, inTextOfLength: Self.chapter,
        ))
        #expect(television.length == 600)
        #expect(phone.length == 2_400)
    }

    @Test("the reach stops at the end of the chapter")
    func reachIsClippedToTheChapter() throws {
        let range = try #require(NarrationReach.range(
            fromPageTop: 9_500, pageLength: Self.pageLength, inTextOfLength: Self.chapter,
        ))
        #expect(range.location == 9_500)
        #expect(range.length == 500)
        #expect(NSMaxRange(range) == Self.chapter)
    }

    /// `enumerateAttribute` raises `NSRangeException` on a range running past
    /// the string, which Swift cannot catch — so a range that would is never
    /// handed back at all.
    @Test("a page beginning at or past the end of the chapter reaches nothing")
    func nothingBeyondTheEnd() {
        #expect(NarrationReach.range(
            fromPageTop: Self.chapter, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.range(
            fromPageTop: Self.chapter + 1, pageLength: Self.pageLength,
            inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.range(
            fromPageTop: -1, pageLength: Self.pageLength, inTextOfLength: Self.chapter,
        ) == nil)
        #expect(NarrationReach.restOfChapter(
            fromPageTop: Self.chapter, inTextOfLength: Self.chapter,
        ) == nil)
    }

    /// `computePages` can emit a synthetic trailing page at `{totalLength, 0}`,
    /// and there is no honest reach from a page with no extent.
    @Test("a page holding no characters reaches nothing")
    func anEmptyPageReachesNothing() {
        #expect(NarrationReach.range(
            fromPageTop: Self.pageTop, pageLength: 0, inTextOfLength: Self.chapter,
        ) == nil)
    }

    /// `narrationStart` is bounded by its own proximity check, in the book's
    /// progress rather than in characters, so this rung deliberately keeps the
    /// old reach.
    @Test("the read-aloud path still runs to the end of the chapter")
    func restOfChapterIsUnbounded() throws {
        let range = try #require(NarrationReach.restOfChapter(
            fromPageTop: Self.pageTop, inTextOfLength: Self.chapter,
        ))
        #expect(range.location == Self.pageTop)
        #expect(NSMaxRange(range) == Self.chapter)
    }
}
