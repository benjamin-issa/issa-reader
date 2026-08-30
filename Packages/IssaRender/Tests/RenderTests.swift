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
