import CoreGraphics
import Foundation
import IssaEPUB
import IssaUI
import Testing

@testable import IssaRender

/// Switching theme repaints the page; it does not rebuild it.
///
/// `ReaderModel` used to treat a theme change as a typography change, because
/// `.foregroundColor` is baked into the attributed text like the font is. It
/// is not like the font: it changes no metric. The reparse it triggered meant a
/// ZIP inflate, an XML parse and a decode of every plate in the chapter, on the
/// main actor, every time the reader switched theme — or every time the system
/// slid into dark mode on its own, mid-sentence, at sunset.
///
/// `.serialized` because every case here builds a `ReaderStyle`, and
/// `bodyFont` reaches CoreText's process-global font matching: parameterised
/// cases that do so in parallel deadlock the whole test process at 0% CPU.
@Suite("Repainting a chapter", .serialized)
@MainActor
struct RecolourTests {
    static func longChapter() throws -> ChapterLayout {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        for item in package.spine {
            let parsed = try HTMLContentParser(style: ReaderStyle())
                .parse(xhtml: try package.archive.read(item.href), baseHref: item.href)
            guard parsed.text.length > 6000 else { continue }
            let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
            layout.layout(pageSize: CGSize(width: 320, height: 480))
            return layout
        }
        throw EPUBError.missingResource("a chapter long enough to paginate")
    }

    /// The consequence if this were false: the reader taps Night in the middle
    /// of a sentence and lands somewhere else in the chapter.
    @Test("the reader does not move")
    func paginationSurvives() throws {
        let layout = try Self.longChapter()
        let before = layout.pages
        #expect(before.count > 2, "a one-page chapter would prove nothing")

        layout.recolour(to: PlatformColor(ReaderTheme.night.text))

        #expect(layout.pages.count == before.count)
        for (old, new) in zip(before, layout.pages) {
            #expect(old.characterRange == new.characterRange, "page \(old.index) moved")
            #expect(old.yOffset == new.yOffset)
            #expect(old.contentBottom == new.contentBottom)
        }
    }

    /// The text itself is untouched — only its ink. A repaint that dropped the
    /// fragment ids would silently kill tap-to-play and every saved highlight
    /// in the chapter.
    @Test("the words, the ids and the pictures all survive")
    func contentSurvives() throws {
        let layout = try Self.longChapter()
        let text = layout.attributedText.string
        let ids = layout.fragmentRanges
        let idsInText = Self.fragmentIDs(in: layout)
        #expect(!idsInText.isEmpty, "the fixture has to carry ids for this to test anything")

        layout.recolour(to: PlatformColor(ReaderTheme.sepia.text))

        #expect(layout.attributedText.string == text)
        #expect(layout.fragmentRanges == ids)
        // The ids the parser wrote into the text, which is a larger set than
        // `fragmentRanges` — that map holds only the ids the *overlay* names,
        // and alice has no overlay while its markup is full of anchors. Both
        // have to come through a repaint: one is what a highlight is stored
        // against, the other is what a tap resolves to.
        #expect(Self.fragmentIDs(in: layout) == idsInText)
    }

    static func fragmentIDs(in layout: ChapterLayout) -> [String] {
        var found: [String] = []
        layout.attributedText.enumerateAttribute(
            .issaFragmentID, in: NSRange(location: 0, length: layout.attributedText.length),
        ) { value, _, _ in if let id = value as? String { found.append(id) } }
        return found
    }

    /// Every run, not just the first. The parser writes `.foregroundColor` per
    /// attribute run, so a repaint that set the attribute on only part of the
    /// chapter would leave a page of black type on a black page.
    @Test("every run is repainted")
    func everyRunRepainted() throws {
        let layout = try Self.longChapter()
        let wanted = PlatformColor(ReaderTheme.night.text)
        layout.recolour(to: wanted)

        var runs = 0
        var wrong = 0
        layout.attributedText.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: layout.attributedText.length),
        ) { value, _, _ in
            runs += 1
            if (value as? PlatformColor) != wanted { wrong += 1 }
        }
        #expect(runs > 0)
        #expect(wrong == 0, "\(wrong) of \(runs) runs kept the old ink")
    }

    /// The one a pure attribute check would miss. `recolour` replaces the
    /// content storage, which throws the layout away, and `pages` is
    /// deliberately not recomputed — so this asks the question that matters:
    /// does the geometry those pages describe still have anything in it.
    ///
    /// It does not discriminate on the explicit `ensureLayout` inside
    /// `recolour`: removing that line leaves this green, because `draw`
    /// enumerates with `.ensuresLayout` and rebuilds the layout itself. That
    /// line is there for `highlightRects`, which does not.
    @Test("the page still draws after a repaint")
    func stillDraws() throws {
        let layout = try Self.longChapter()
        let page = try #require(layout.pages.dropFirst(2).first)
        let before = DrawingTests.inkCoverage(layout, page: page)
        #expect(before > 0.001, "the fixture page has to have ink on it to start with")

        layout.recolour(to: PlatformColor(ReaderTheme.sepia.text))
        let after = DrawingTests.inkCoverage(layout, page: page)
        #expect(after > 0.001, "the page went blank: coverage \(before) → \(after)")
    }

    /// A repaint must not shift what a page paints, which is what `draw` and
    /// the spoken page text both read.
    @Test("a repainted page still paints its own characters")
    func paintedRangeSurvives() throws {
        let layout = try Self.longChapter()
        layout.recolour(to: PlatformColor(ReaderTheme.slate.text))

        for page in layout.pages {
            let painted = layout.paintedCharacterRange(for: page)
            #expect(painted.location >= page.characterRange.location,
                    "page \(page.index) paints characters before its own range")
            #expect(painted.location + painted.length
                <= page.characterRange.location + page.characterRange.length + 1,
                "page \(page.index) paints into the next page")
        }
    }
}
