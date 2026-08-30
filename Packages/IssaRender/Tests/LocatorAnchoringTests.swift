import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaRender

@Suite("Restoring a saved position")
struct LocatorAnchoringTests {
    let text = """
    Chapter One. Alice was beginning to get very tired of sitting by her sister \
    on the bank, and of having nothing to do. So she considered in her own mind \
    whether the pleasure of making a daisy-chain would be worth the trouble. \
    Chapter One. There was nothing so very remarkable in that.
    """

    /// The sentence id is the strongest anchor: it comes from the markup, so it
    /// does not move when the type size does.
    @Test("A narrated fragment wins over everything else")
    func fragmentWins() {
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(fragments: ["ch1-s3"], progression: 0.9, charOffset: 999),
        )
        let offset = LocatorAnchoring.characterOffset(
            for: locator, in: text, fragmentRanges: ["ch1-s3": NSRange(location: 13, length: 20)],
        )
        #expect(offset == 13)
    }

    /// A locator written before the reader changed font size still has to land
    /// on the same words, which only the quoted text can guarantee.
    @Test("Remembered words re-anchor a position exactly")
    func quotedTextAnchors() {
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.5, charOffset: 4_000),
            text: .init(highlight: "So she considered in her own mind"),
        )
        let offset = LocatorAnchoring.characterOffset(for: locator, in: text, fragmentRanges: [:])
        #expect(offset == (text as NSString).range(of: "So she considered").location)
    }

    /// "Chapter One" appears twice here, as repeated phrases do in real books.
    /// Taking the first match would throw the reader back to the top.
    @Test("A repeated phrase resolves to the occurrence nearest the recorded progress")
    func picksNearestOccurrence() {
        let second = (text as NSString).range(of: "Chapter One", options: .backwards).location
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: Double(second) / Double((text as NSString).length)),
            text: .init(highlight: "Chapter One. There was nothing"),
        )
        let offset = LocatorAnchoring.characterOffset(for: locator, in: text, fragmentRanges: [:])
        #expect(offset == second)
    }

    @Test("A quote that is no longer in the chapter falls back to the offset")
    func fallsBackToOffset() {
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.1, charOffset: 42),
            text: .init(highlight: "words the publisher has since deleted entirely"),
        )
        #expect(LocatorAnchoring.characterOffset(for: locator, in: text, fragmentRanges: [:]) == 42)
    }

    /// A much shorter chapter means a different revision of the file; a raw
    /// index into it would point somewhere arbitrary.
    @Test("An offset past the end of the chapter is not used")
    func rejectsStaleOffset() {
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(progression: 0.5, charOffset: 100_000),
        )
        let offset = LocatorAnchoring.characterOffset(for: locator, in: text, fragmentRanges: [:])
        #expect(offset == Int(Double((text as NSString).length) * 0.5))
    }

    @Test("Quoting a position records the words at it, not the line breaks")
    func quoting() {
        let quote = LocatorAnchoring.quote(from: "First line\nsecond line", at: 0, length: 22)
        #expect(quote?.highlight == "First line second line")
        #expect(LocatorAnchoring.quote(from: "x", at: 5) == nil)
    }

    /// Positions written by the official client carry the manifest's absolute,
    /// percent-encoded href; the EPUB spine's is relative to the package.
    @Test("Hrefs match across the forms different clients write")
    func hrefMatching() {
        let locator = ReadiumLocator(
            href: "/OEBPS/text/chapter%2001.xhtml", type: "application/xhtml+xml")
        #expect(locator.matchesHref("text/chapter 01.xhtml"))
        #expect(locator.matchesHref("./text/chapter 01.xhtml"))
        #expect(locator.matchesHref("EPUB/text/chapter 01.xhtml#frag"))
        #expect(!locator.matchesHref("text/chapter 02.xhtml"))
        // Not so tolerant that two chapters of the same name in different
        // directories collapse into one.
        #expect(!locator.matchesHref("images/chapter 01.xhtml"))
    }
}

/// Chapter labelling, which Gutenberg's EPUBs make harder than it looks: a
/// whole book in one spine file, chapters distinguished only by anchor.
@Suite("Labelling a place in the book")
struct ChapterLabellingTests {
    let text = String(repeating: "a", count: 100)
        + "Chapter One begins here. " + String(repeating: "b", count: 100)
        + "Chapter Two begins here. " + String(repeating: "c", count: 100)

    @Test("a hit is labelled with the chapter it falls in, not the file's first")
    func labelsByAnchor() {
        let ranges = ["c1": NSRange(location: 100, length: 24), "c2": NSRange(location: 225, length: 24)]
        let nav = [
            EPUBPackage.NavPoint(title: "One", href: "book.xhtml", fragment: "c1"),
            EPUBPackage.NavPoint(title: "Two", href: "book.xhtml", fragment: "c2"),
        ]
        let hits = BookSearch.hits(
            for: "begins here", in: text, chapterIndex: 0, chapterTitle: "The Whole Book",
            navigation: nav, fragmentRanges: ranges,
        )
        #expect(hits.count == 2)
        #expect(hits[0].chapterTitle == "One")
        #expect(hits[1].chapterTitle == "Two")
    }

    /// Before the first anchor there is no chapter yet — the file's own title
    /// is the honest answer, not the first chapter's.
    @Test("text before the first anchor keeps the file's title")
    func beforeFirstAnchor() {
        let hits = BookSearch.hits(
            for: "aaaa", in: text, chapterIndex: 0, chapterTitle: "Front Matter",
            navigation: [EPUBPackage.NavPoint(title: "One", href: "b.xhtml", fragment: "c1")],
            fragmentRanges: ["c1": NSRange(location: 100, length: 24)],
        )
        #expect(hits.first?.chapterTitle == "Front Matter")
    }

    @Test("a search excerpt points at the match wherever it was clipped")
    func excerptRange() {
        let hits = BookSearch.hits(
            for: "Chapter Two", in: text, chapterIndex: 0, chapterTitle: "Book")
        let hit = try! #require(hits.first)
        #expect(hit.excerpt[hit.excerptMatchRange] == "Chapter Two")
    }

    /// A runaway match count on a common word would build a list nobody can use
    /// and hold the whole chapter in memory twice over.
    @Test("matches are capped per chapter")
    func capped() {
        let haystack = String(repeating: "the ", count: 500)
        let hits = BookSearch.hits(
            for: "the", in: haystack, chapterIndex: 0, chapterTitle: "Book", limitPerChapter: 10)
        #expect(hits.count == 10)
    }
}

/// Where a tap lands. The old test compared a padded-frame x against the canvas
/// width, so the back zone was a margin narrower than intended and shifted
/// inward — and over narrated text it was unreachable altogether.
@Suite("Tap zones")
struct TapZoneTests {
    typealias Zone = ReaderTapZone

    @Test("the outer quarters turn pages and the middle half toggles chrome")
    func zones() {
        let width: CGFloat = 300
        let margin: CGFloat = 24
        let full = width + margin * 2   // 348

        #expect(Zone.of(x: 0, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: full * 0.1, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: full * 0.5, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full * 0.9, pageWidth: width, margin: margin) == .forward)
        #expect(Zone.of(x: full, pageWidth: width, margin: margin) == .forward)
    }

    /// The boundaries are measured against the frame the tap arrives in — the
    /// padded one — not the canvas inside it.
    @Test("boundaries account for the page margin")
    func boundariesIncludeMargin() {
        let width: CGFloat = 300
        let margin: CGFloat = 24
        let full = width + margin * 2

        // Just inside a quarter of the FULL width is still back; just outside is
        // middle. Measured against the canvas alone these would both be wrong.
        #expect(Zone.of(x: full * 0.25 - 1, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: full * 0.25 + 1, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full * 0.75 - 1, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full * 0.75 + 1, pageWidth: width, margin: margin) == .forward)
    }

    @Test("a degenerate width does not turn pages")
    func degenerate() {
        #expect(Zone.of(x: 10, pageWidth: 0, margin: 0) == .middle)
    }
}
