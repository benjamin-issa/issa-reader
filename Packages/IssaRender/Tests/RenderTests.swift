import Foundation
import IssaEPUB
import Testing

@testable import IssaRender

struct HTMLContentParserTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "epub"))
    }

    @Test("keeps text that follows an inline element")
    func preservesMixedContent() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>Hello <b>world</b> again</p>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        // Losing the tail text after an inline element is the classic mixed
        // content bug; it silently mangles ordinary prose.
        #expect(result.text.string.contains("Hello world again"))
    }

    @Test("records a character range for every element id")
    func recordsFragmentRanges() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p><span id="ch01-s0">First sentence. </span><span id="ch01-s1">Second sentence.</span></p>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        let first = try #require(result.fragmentRanges["ch01-s0"])
        let second = try #require(result.fragmentRanges["ch01-s1"])

        let string = result.text.string as NSString
        #expect(string.substring(with: first).contains("First sentence"))
        #expect(string.substring(with: second).contains("Second sentence"))
        // Ranges must not overlap, or a highlight would cover both sentences.
        #expect(first.location + first.length <= second.location)
    }

    @Test("substitutes HTML named entities XML does not define")
    func substitutesEntities() throws {
        // &nbsp; is fatal to XMLParser unless rewritten; plenty of real books
        // use it, and without this they simply fail to open.
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body><p>a&nbsp;b&mdash;c&hellip;</p></body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        #expect(result.text.string.contains("\u{00A0}"))
        #expect(result.text.string.contains("\u{2014}"))
        #expect(result.text.string.contains("\u{2026}"))
    }

    @Test("collapses source whitespace the way HTML does")
    func collapsesWhitespace() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p>one     two
             three</p>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        #expect(result.text.string.contains("one two three"))
    }

    /// Publishers put verse and code directly in `<pre>` — Gutenberg marks up
    /// poetry this way. The collapse guard used to read the *incoming*
    /// context rather than the element's own, so a bare `<pre>`'s text lost
    /// every line break while the nested `<pre><code>` form kept them.
    @Test("a bare <pre> keeps its line breaks and indentation")
    func preservesPreformattedText() throws {
        let html = Data(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><pre>line one\n  line two\nline three</pre></body></html>".utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        #expect(result.text.string.contains("line one\n  line two\nline three"))
    }

    @Test("text following an inline element inside <pre> stays preformatted")
    func preservesPreformattedTails() throws {
        let html = Data(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><pre>one <i>two</i>\n  three</pre></body></html>".utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        #expect(result.text.string.contains("two\n  three"))
    }

    @Test("flags structure the native renderer cannot represent")
    func flagsComplexity() throws {
        let plain = Data("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Just prose.</p></body></html>".utf8)
        let simple = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: plain, baseHref: "c.xhtml")
        #expect(simple.complexity.requiresWebView == false)

        let tabular = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body><table><tr><td>a</td></tr></table></body></html>
        """.utf8)
        let complex = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: tabular, baseHref: "c.xhtml")
        #expect(complex.complexity.hasTables)
        #expect(complex.complexity.requiresWebView)
    }

    @Test("parses a real chapter out of a real book")
    func parsesRealChapter() throws {
        let package = try EPUBPackage.open(url: try Self.fixture("alice"))
        // Pick a spine item with real prose rather than the cover or nav page.
        var parsed: HTMLContentParser.Result?
        for item in package.spine {
            let data = try package.archive.read(item.href)
            let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: data, baseHref: item.href)
            if result.text.length > 1000 { parsed = result; break }
        }
        let result = try #require(parsed, "no substantial chapter found")
        #expect(result.text.length > 1000)
        #expect(!result.text.string.contains("<"))
    }
}

@MainActor
struct PaginatorTests {
    static func readalongChapter() throws -> (NSAttributedString, [String: NSRange]) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let first = try #require(package.spine.first)
        let data = try package.archive.read(first.href)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: data, baseHref: first.href)
        return (result.text, result.fragmentRanges)
    }

    @Test("splits a chapter into pages that cover all of it")
    func paginatesRealChapter() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/alice", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        var chapter: HTMLContentParser.Result?
        for item in package.spine {
            let parsed = try HTMLContentParser(style: ReaderStyle())
                .parse(xhtml: try package.archive.read(item.href), baseHref: item.href)
            if parsed.text.length > 4000 { chapter = parsed; break }
        }
        let content = try #require(chapter, "no long chapter found")

        let layout = ChapterLayout(text: content.text, fragmentRanges: content.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))

        #expect(layout.pages.count > 1, "a long chapter should need more than one page")

        // Pages must tile the chapter: contiguous, no gaps, no overlaps.
        var expectedStart = 0
        for page in layout.pages {
            #expect(page.characterRange.location == expectedStart)
            expectedStart = page.characterRange.location + page.characterRange.length
        }
        #expect(expectedStart == content.text.length)
    }

    @Test("a narrower page yields more pages")
    func reflowsWithSize() throws {
        let (text, ranges) = try Self.readalongChapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)

        layout.layout(pageSize: CGSize(width: 600, height: 400))
        let wide = layout.pages.count
        layout.layout(pageSize: CGSize(width: 240, height: 200))
        let narrow = layout.pages.count

        #expect(narrow >= wide)
        #expect(narrow > 0)
    }

    @Test("resolves highlight rectangles for a narrated fragment")
    func highlightRects() throws {
        let (text, ranges) = try Self.readalongChapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))

        let fragment = "ch01-s1"
        let page = try #require(layout.page(containingFragment: fragment))
        let rects = layout.highlightRects(forFragment: fragment, on: page)

        #expect(!rects.isEmpty, "a narrated sentence must resolve to at least one rectangle")
        for rect in rects {
            #expect(rect.width > 0)
            #expect(rect.height > 0)
        }
    }

    @Test("an unknown fragment yields no rectangles rather than crashing")
    func unknownFragment() throws {
        let (text, ranges) = try Self.readalongChapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))
        let page = try #require(layout.pages.first)
        #expect(layout.highlightRects(forFragment: "does-not-exist", on: page).isEmpty)
        #expect(layout.page(containingFragment: "does-not-exist") == nil)
    }

    @Test("every narrated fragment can be located on some page")
    func everyFragmentIsLocatable() throws {
        let (text, ranges) = try Self.readalongChapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 300, height: 220))

        for fragmentID in ranges.keys {
            let page = layout.page(containingFragment: fragmentID)
            #expect(page != nil, "fragment \(fragmentID) is on no page")
        }
    }
}

/// Regression tests for fragment-id nesting.
///
/// Media overlays reference the innermost sentence span, but real EPUB markup
/// wraps those spans in sections, divs and paragraphs that also carry ids.
struct FragmentNestingTests {
    @Test("an outer element's id does not overwrite the sentence spans inside it")
    func innermostIDWins() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <section id="pg-header">
          <p id="para1"><span id="pg-header-s0">First. </span><span id="pg-header-s1">Second.</span></p>
        </section>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        let text = result.text

        // Every character of "First." must be attributed to the innermost span,
        // not to the section or paragraph that wraps it. Getting this wrong
        // highlights an entire chapter instead of one sentence.
        let firstRange = try #require(result.fragmentRanges["pg-header-s0"])
        let attribute = text.attribute(.issaFragmentID, at: firstRange.location, effectiveRange: nil) as? String
        #expect(attribute == "pg-header-s0")

        let secondRange = try #require(result.fragmentRanges["pg-header-s1"])
        let secondAttribute = text.attribute(.issaFragmentID, at: secondRange.location, effectiveRange: nil) as? String
        #expect(secondAttribute == "pg-header-s1")
    }

    @Test("an outer id still covers text no inner span claims")
    func outerIDFillsGaps() throws {
        let html = Data("""
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <section id="outer">Loose text. <span id="inner-s0">Claimed.</span></section>
        </body></html>
        """.utf8)
        let result = try HTMLContentParser(style: ReaderStyle()).parse(xhtml: html, baseHref: "c.xhtml")
        let outerRange = try #require(result.fragmentRanges["outer"])
        let attribute = result.text.attribute(.issaFragmentID, at: outerRange.location, effectiveRange: nil) as? String
        #expect(attribute == "outer")
        // The chapter must not open on stray whitespace from the source markup.
        #expect(result.text.string.hasPrefix("Loose text."))

        let innerRange = try #require(result.fragmentRanges["inner-s0"])
        let inner = result.text.attribute(.issaFragmentID, at: innerRange.location, effectiveRange: nil) as? String
        #expect(inner == "inner-s0")
    }
}

/// Pagination and drawing have to agree about what is on a page.
///
/// They disagreed once: pagination refused to split a line across a boundary,
/// but drawing bounded itself by the page rectangle, so the next page's opening
/// line was painted at the bottom of the current one and clipped mid-glyph —
/// then repeated in full on the turn.
@MainActor
struct PageBoundaryTests {
    static func longChapterLayout() throws -> ChapterLayout {
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
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no long chapter"])
    }

    @Test("a page paints only its own characters")
    func paintsOnlyItsOwnRange() throws {
        let layout = try Self.longChapterLayout()
        #expect(layout.pages.count > 2)

        for page in layout.pages {
            let painted = layout.paintedCharacterRange(for: page)
            // The painted span must not reach past what pagination assigned.
            #expect(painted.location >= page.characterRange.location,
                    "page \(page.index) paints characters before its own range")
            #expect(painted.location + painted.length
                <= page.characterRange.location + page.characterRange.length + 1,
                "page \(page.index) paints into the next page")
        }
    }

    @Test("pages tile the chapter with no gap and no overlap")
    func pagesTile() throws {
        let layout = try Self.longChapterLayout()
        var expected = 0
        for page in layout.pages {
            #expect(page.characterRange.location == expected)
            expected = page.characterRange.location + page.characterRange.length
        }
        #expect(expected == layout.attributedText.length)
    }

    @Test("page tops are strictly increasing, and the last runs to infinity")
    func boundariesAscend() throws {
        let layout = try Self.longChapterLayout()
        var previous = -CGFloat.infinity
        for page in layout.pages {
            #expect(page.yOffset > previous || page.index == 0)
            #expect(page.contentBottom > page.yOffset)
            previous = page.yOffset
        }
        #expect(layout.pages.last?.contentBottom == .infinity)
    }

    /// A paragraph too long to fit the remaining room on a page used to move
    /// in its entirety to the next one — pagination refused to split a
    /// fragment (a whole paragraph) across a boundary, only a line. For a
    /// paragraph long enough that even a fresh page could not hold it, that
    /// left no boundary anywhere that worked: whichever page it started on,
    /// its tail ran past the page's own height, and the fixed-size canvas
    /// clipped whatever didn't fit — silently. This is the fixture that
    /// forces it: one paragraph with no internal breaks, long enough to run
    /// several times the height of the page.
    static func oneGiantParagraphLayout(pageHeight: CGFloat = 400) throws -> ChapterLayout {
        let sentence = "The lamplighter went from post to post along the empty street. "
        let xhtml = "<html><body><p>" + String(repeating: sentence, count: 40) + "</p></body></html>"
        let result = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: Data(xhtml.utf8), baseHref: "c.xhtml")
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 320, height: pageHeight))
        return layout
    }

    @Test("no page's content runs past the height it was given")
    func noPageOverflowsItsHeight() throws {
        let layout = try Self.oneGiantParagraphLayout()
        #expect(layout.pages.count > 3, "the fixture should span several pages")
        for page in layout.pages where page.contentBottom.isFinite {
            let used = page.contentBottom - page.yOffset
            #expect(used <= 400 + 0.5,
                    "page \(page.index) holds \(used)pt of content in a 400pt page — its tail would be clipped")
        }
    }

    @Test("no page wastes more than about a line's worth of room")
    func noPageWastesALotOfSpace() throws {
        let layout = try Self.oneGiantParagraphLayout()
        for page in layout.pages where page.contentBottom.isFinite {
            let used = page.contentBottom - page.yOffset
            let wasted = 400 - used
            #expect(wasted < 60,
                    "page \(page.index) leaves \(wasted)pt unused out of 400 — a whole paragraph moved that should have had its lines split")
        }
    }

    /// The strongest check: every character of the chapter is painted on
    /// exactly one page. `pagesTile()` above proves this for `characterRange`,
    /// which `computePages` assigns; this proves it independently for
    /// `paintedCharacterRange`, which `draw` and `spokenText` actually use —
    /// the two disagreeing is exactly the class of bug this suite exists for.
    @Test("the painted ranges of every page reconstruct the whole chapter, with no gap and no overlap")
    func paintedRangesTileTheChapter() throws {
        let layout = try Self.oneGiantParagraphLayout()
        var expected = 0
        for page in layout.pages {
            let painted = layout.paintedCharacterRange(for: page)
            guard painted.length > 0 else { continue }
            #expect(painted.location == expected,
                    "page \(page.index) painted range starts at \(painted.location), expected \(expected)")
            expected = NSMaxRange(painted)
        }
        #expect(expected == layout.attributedText.length)
    }

    @Test("a real long chapter also never wastes more than about a line of room")
    func realChapterNoWaste() throws {
        let layout = try Self.longChapterLayout()
        for page in layout.pages where page.contentBottom.isFinite {
            let wasted = 480 - (page.contentBottom - page.yOffset)
            #expect(wasted < 60, "page \(page.index) wastes \(wasted)pt")
        }
    }

    /// Sentence spans across several pages, so some span inevitably straddles
    /// a page boundary — the shape a read-along chapter always has.
    static func spannedParagraphLayout() throws -> ChapterLayout {
        let sentence = "The lamplighter went from post to post along the empty street. "
        var body = "<p>"
        for index in 0 ..< 80 { body += "<span id=\"s\(index)\">\(sentence)</span>" }
        body += "</p>"
        let result = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: Data(("<html><body>" + body + "</body></html>").utf8), baseHref: "c.xhtml")
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 320, height: 400))
        return layout
    }

    /// `highlightRects` and `rects(forRange:)` were the last two callers still
    /// bounding by `page.height` after pages started ending mid-paragraph: a
    /// narrated sentence continuing onto the next page painted a bar in the
    /// blank band below this page's last line — a tinted stripe under no text,
    /// held for as long as the sentence was spoken.
    @Test("highlight rects stop at the page's drawn content, not its height")
    func highlightRectsRespectContentBottom() throws {
        let layout = try Self.spannedParagraphLayout()
        #expect(layout.pages.count > 3, "the fixture should span several pages")

        // The fixture must actually exercise the seam: at least one span has
        // characters on two pages.
        let straddlers = layout.fragmentRanges.filter { _, range in
            layout.pages.filter { NSIntersectionRange(range, $0.characterRange).length > 0 }.count > 1
        }
        #expect(!straddlers.isEmpty, "no span straddles a page boundary")

        for page in layout.pages {
            let localBottom = page.contentBottom.isFinite
                ? page.contentBottom - page.yOffset : CGFloat.greatestFiniteMagnitude
            for (id, range) in layout.fragmentRanges {
                for rect in layout.highlightRects(forFragment: id, on: page) {
                    #expect(rect.minY < localBottom,
                            "page \(page.index): \(id) highlights at \(rect.minY), below the content bottom \(localBottom)")
                }
                for rect in layout.rects(forRange: range, on: page) {
                    #expect(rect.minY < localBottom,
                            "page \(page.index): \(id) selection reaches \(rect.minY), below the content bottom \(localBottom)")
                }
            }
        }
    }
}
