import CoreGraphics
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

    /// Page breaks fall mid-sentence far more often than not, so a position
    /// saved at the top of a page names a sentence that began on the page
    /// before. Returning that sentence's start put the reader there, the close
    /// then saved *that* page, and the position walked back one page per open.
    @Test("An offset inside the fragment refines it to the exact place")
    func offsetInsideFragmentRefines() {
        let ranges = ["ch1-s2": NSRange(location: 13, length: 60)]
        let inside = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(fragments: ["ch1-s2"], progression: 0.2, charOffset: 40),
        )
        #expect(LocatorAnchoring.characterOffset(for: inside, in: text, fragmentRanges: ranges) == 40)

        // An offset outside the sentence is from another rendering of the
        // text; the sentence keeps its authority.
        let stale = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            locations: .init(fragments: ["ch1-s2"], progression: 0.2, charOffset: 200),
        )
        #expect(LocatorAnchoring.characterOffset(for: stale, in: text, fragmentRanges: ranges) == 13)
    }

    /// The same drift from the writing side: the fragment a page anchors on
    /// must begin on that page. The one covering its first character usually
    /// does not, and restoring to it lands on the page before.
    @Test("A saved page anchors on a fragment that begins on it")
    @MainActor
    func savedPageAnchorsOnItsOwnFragment() throws {
        // One long paragraph of numbered sentences, laid out narrow enough
        // that every page break falls inside a sentence.
        let style = ReaderStyle()
        let attributed = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]
        for index in 0..<40 {
            let start = attributed.length
            attributed.append(NSAttributedString(
                string: "Sentence number \(index) rambles on for long enough to wrap onto another line. ",
                attributes: [.font: style.bodyFont(), .issaFragmentID: "s\(index)"],
            ))
            ranges["s\(index)"] = NSRange(location: start, length: attributed.length - start)
        }
        let layout = ChapterLayout(text: attributed, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 200, height: 120))
        try #require(layout.pages.count > 2)

        for page in layout.pages.dropFirst() where page.characterRange.length > 0 {
            let start = page.characterRange.location
            let covering = attributed.attribute(.issaFragmentID, at: start, effectiveRange: nil) as? String
            let anchor = layout.firstFragment(beginningOn: page)
            if let anchor {
                let range = try #require(ranges[anchor])
                #expect(range.location >= start, "\(anchor) began before page \(page.index)")
                #expect(NSLocationInRange(range.location, page.characterRange))
                // What a restore does with it: back to this page, never the one before.
                let locator = ReadiumLocator(
                    href: "ch.xhtml", type: "application/xhtml+xml",
                    locations: .init(fragments: [anchor], charOffset: start),
                )
                let offset = try #require(LocatorAnchoring.characterOffset(
                    for: locator, in: attributed.string, fragmentRanges: ranges))
                #expect(layout.page(containingOffset: offset)?.index == page.index)
            }
            // The covering fragment is the trap: whenever it began earlier it
            // must not have been chosen.
            if let covering, let range = ranges[covering], range.location < start {
                #expect(anchor != covering)
            }
        }
        // The fixture actually exercises the straddling case.
        let straddles = layout.pages.dropFirst().contains { page in
            guard page.characterRange.length > 0,
                  let id = attributed.attribute(
                    .issaFragmentID, at: page.characterRange.location, effectiveRange: nil) as? String,
                  let range = ranges[id] else { return false }
            return range.location < page.characterRange.location
        }
        #expect(straddles, "no page break fell inside a sentence; the fixture proves nothing")
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

    /// The reader jumps to a hit by selecting `excerpt[excerptMatchRange]`:
    /// the selection starts at `charOffset` and is sized on the text it is
    /// handed, so that text must be the match alone — handing over the whole
    /// excerpt once selected a sentence and a half of context.
    @Test("the matched text sizes a selection covering exactly the match")
    func matchedTextSizesSelection() {
        let hits = BookSearch.hits(
            for: "chapter two", in: text, chapterIndex: 0, chapterTitle: "Book")
        let hit = try! #require(hits.first)
        let matched = String(hit.excerpt[hit.excerptMatchRange]) as NSString
        let selected = (text as NSString).substring(
            with: NSRange(location: hit.charOffset, length: matched.length))
        #expect(selected == "Chapter Two")
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

    @Test("the outer strips turn pages and the rest toggles chrome")
    func zones() {
        let width: CGFloat = 300
        let margin: CGFloat = 24
        let full = width + margin * 2   // 348, so the strip is 24 + 44 = 68

        #expect(Zone.of(x: 0, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: 40, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: full * 0.5, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full - 40, pageWidth: width, margin: margin) == .forward)
        #expect(Zone.of(x: full, pageWidth: width, margin: margin) == .forward)
    }

    /// The boundaries are measured against the frame the tap arrives in — the
    /// padded one — not the canvas inside it.
    @Test("boundaries account for the page margin")
    func boundariesIncludeMargin() {
        let width: CGFloat = 300
        let margin: CGFloat = 24
        let full = width + margin * 2
        let strip = margin + 44

        #expect(Zone.of(x: strip - 1, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: strip + 1, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full - strip - 1, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: full - strip + 1, pageWidth: width, margin: margin) == .forward)
    }

    /// The reason the strips are points and not a fraction. A quarter of an
    /// iPad's width is 256pt — 232pt of it live text — so a reader aiming at a
    /// sentence in the first third of the line turned the page instead.
    @Test("the strip does not grow with the page")
    func stripIsPointBased() {
        let margin: CGFloat = 24
        let phone: CGFloat = 393 - margin * 2
        let pad: CGFloat = 1024 - margin * 2

        // Same absolute boundary on both, and a point that is inside a quarter
        // of the iPad's width is emphatically middle.
        #expect(Zone.of(x: 100, pageWidth: phone, margin: margin) == .middle)
        #expect(Zone.of(x: 100, pageWidth: pad, margin: margin) == .middle)
        #expect(Zone.of(x: 250, pageWidth: pad, margin: margin) == .middle)
        #expect(Zone.of(x: 60, pageWidth: pad, margin: margin) == .back)
    }

    /// A Slide Over is narrower than two strips plus a usable middle, so the
    /// fraction still caps them.
    @Test("strips stay a quarter each on a narrow page")
    func narrowPageCapsTheStrip() {
        let margin: CGFloat = 24
        let width: CGFloat = 200 - margin * 2   // full = 200, so the cap is 50

        #expect(Zone.of(x: 49, pageWidth: width, margin: margin) == .back)
        #expect(Zone.of(x: 51, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: 100, pageWidth: width, margin: margin) == .middle)
        #expect(Zone.of(x: 151, pageWidth: width, margin: margin) == .forward)
    }

    @Test("a degenerate width does not turn pages")
    func degenerate() {
        #expect(Zone.of(x: 10, pageWidth: 0, margin: 0) == .middle)
    }
}

/// `progression` is decoded verbatim from the server, and the conversion to a
/// character index used to trap on anything non-finite or huge — on every
/// open of that book, with nothing the reader could do about it.
@Suite("A hostile progression")
struct HostileProgressionTests {
    @Test("non-finite and out-of-range values resolve or fall through, never trap",
          arguments: [Double.nan, .infinity, -.infinity, 1e300, -1, 2, 0.5])
    func neverTraps(progression: Double) {
        let text = String(repeating: "abcdefghij", count: 10)
        let locator = ReadiumLocator(
            href: "ch01.xhtml", type: "application/xhtml+xml",
            title: nil,
            locations: .init(progression: progression),
            text: .init(before: nil, highlight: "abcdefghijabcdefghij"),
        )
        let offset = LocatorAnchoring.characterOffset(for: locator, in: text, fragmentRanges: [:])
        if let offset {
            #expect(offset >= 0 && offset < 100)
        } else {
            #expect(!progression.isFinite, "a finite progression always names some character")
        }
    }

    @Test("the offset a progression names is clamped into the text")
    func clamps() {
        #expect(LocatorAnchoring.offset(forProgression: 2, length: 10) == 9)
        #expect(LocatorAnchoring.offset(forProgression: -1, length: 10) == 0)
        #expect(LocatorAnchoring.offset(forProgression: 0.5, length: 10) == 5)
        #expect(LocatorAnchoring.offset(forProgression: .nan, length: 10) == nil)
        #expect(LocatorAnchoring.offset(forProgression: 0.5, length: 0) == nil)
        #expect(LocatorAnchoring.offset(forProgression: nil, length: 10) == nil)
    }
}
