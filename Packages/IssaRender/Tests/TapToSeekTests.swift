import CoreGraphics
import Foundation
import IssaEPUB
import Testing

@testable import IssaRender

/// Tapping a sentence has to start the narration at that sentence. The whole
/// interaction rests on turning a point back into a fragment id, so these
/// exercise the round trip against a real aligned chapter rather than trusting
/// that the geometry lines up.
@Suite("Tapping a sentence")
@MainActor
struct TapToSeekTests {
    static func chapter() throws -> (NSAttributedString, [String: NSRange]) {
        try PaginatorTests.readalongChapter()
    }

    @Test("the point at the middle of a sentence resolves to that sentence")
    func roundTrip() throws {
        let (text, ranges) = try Self.chapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))

        var checked = 0
        for id in ranges.keys.sorted() {
            guard let page = layout.page(containingFragment: id) else { continue }
            let rects = layout.highlightRects(forFragment: id, on: page)
            // Use the widest rectangle: a sentence that wraps has a short
            // fragment at either end where a midpoint may land on a neighbour.
            guard let rect = rects.max(by: { $0.width < $1.width }), rect.width > 30 else { continue }

            let point = CGPoint(x: rect.midX, y: rect.midY)
            #expect(layout.fragmentID(at: point, on: page) == id,
                    "tapping the middle of \(id) should resolve to \(id)")
            checked += 1
            if checked >= 12 { break }
        }
        #expect(checked >= 4, "the fixture should offer several sentences to tap")
    }

    /// The second line of a wrapped paragraph is where an off-by-a-line error in
    /// the hit test shows up: the index would come back short by a whole line.
    @Test("a tap on a later line of a paragraph does not resolve to the first")
    func wrappedLines() throws {
        let (text, ranges) = try Self.chapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 260, height: 560))

        let page = try #require(layout.pages.first)
        // Two points a good way apart vertically inside the page must not
        // report the same character index.
        let high = try #require(layout.characterIndex(at: CGPoint(x: 40, y: 30), on: page))
        let low = try #require(layout.characterIndex(at: CGPoint(x: 40, y: 300), on: page))
        #expect(low > high)
        #expect(NSLocationInRange(high, page.characterRange))
        #expect(NSLocationInRange(low, page.characterRange))
    }

    @Test("a tap in the margin below the text does not crash or wrap around")
    func belowText() throws {
        let (text, ranges) = try Self.chapter()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 340, height: 560))
        let page = try #require(layout.pages.first)

        let index = layout.characterIndex(at: CGPoint(x: 10, y: 559), on: page)
        if let index { #expect(index >= page.characterRange.location) }
    }
}

/// The fixture's sentences each sit in their own paragraph, so every layout
/// fragment is one or two lines and a fragment-versus-line coordinate mistake
/// cannot show. Real prose puts several sentences in one long paragraph, which
/// is a single multi-line layout fragment — this builds exactly that.
@Suite("Tapping inside a long paragraph")
@MainActor
struct LongParagraphTapTests {
    static let sentences = [
        "This ebook is for the use of anyone anywhere in the United States and most other parts of the world at no cost and with almost no restrictions whatsoever. ",
        "You may copy it, give it away or re-use it under the terms of the Project Gutenberg License included with this ebook or online at www.gutenberg.org. ",
        "If you are not located in the United States, you will have to check the laws of the country where you are located before using this eBook.",
    ]

    static func paragraph() -> (NSAttributedString, [String: NSRange]) {
        let text = NSMutableAttributedString()
        var ranges: [String: NSRange] = [:]
        let style = ReaderStyle()
        for (index, sentence) in sentences.enumerated() {
            let start = text.length
            text.append(NSAttributedString(
                string: sentence,
                attributes: [.font: style.bodyFont(), .issaFragmentID: "s\(index + 1)"],
            ))
            ranges["s\(index + 1)"] = NSRange(location: start, length: text.length - start)
        }
        return (text, ranges)
    }

    @Test("every sentence in one wrapped paragraph resolves to itself")
    func resolvesWithinOneFragment() throws {
        let (text, ranges) = Self.paragraph()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 320, height: 900))

        let page = try #require(layout.pages.first)
        #expect(layout.pages.count == 1, "the whole paragraph should fit on one page")

        for id in ranges.keys.sorted() {
            let rects = layout.highlightRects(forFragment: id, on: page)
            let rect = try #require(rects.max(by: { $0.width < $1.width }))
            let point = CGPoint(x: rect.midX, y: rect.midY)
            #expect(layout.fragmentID(at: point, on: page) == id,
                    "tapping \(id) at \(point) resolved elsewhere")
        }
    }

    /// Walking down the paragraph line by line must produce indices that only
    /// ever move forward, by roughly a line's worth each time.
    @Test("indices increase monotonically down a wrapped paragraph")
    func monotonic() throws {
        let (text, ranges) = Self.paragraph()
        let layout = ChapterLayout(text: text, fragmentRanges: ranges)
        layout.layout(pageSize: CGSize(width: 320, height: 900))
        let page = try #require(layout.pages.first)

        var previous = -1
        for y in stride(from: 6.0, to: 200.0, by: 8.0) {
            guard let index = layout.characterIndex(at: CGPoint(x: 160, y: y), on: page) else { continue }
            #expect(index >= previous, "index went backwards at y=\(y)")
            previous = index
        }
        #expect(previous > 100, "walking the paragraph should reach well into it")
    }
}


/// The shape real books actually have — and the one the suites above do not.
///
/// `Fixtures/readalong.epub` puts every sentence in its own `<p>`, so a layout
/// fragment is one or two lines and the hand-rolled line search inside a
/// multi-line paragraph is barely exercised. `LongParagraphTapTests` builds a
/// wrapped paragraph but attaches only a font and a fragment id — **no
/// paragraph style at all**, so none of `lineHeightMultiple`, `paragraphSpacing`,
/// hyphenation, justification or head indent is present. Storyteller puts its
/// ids on inline spans and leaves the `<p>` bare, so a real prose paragraph is
/// one `NSTextLayoutFragment` holding six to ten lines and several narrated
/// sentences, all under a paragraph style. That intersection had no coverage,
/// and it is where tapping stopped working.
///
/// The property asserted is the one that cannot be argued with: tapping and
/// highlighting read the *same* `fragmentRanges` table in opposite directions,
/// so they must be mutual inverses. Where the highlight draws a sentence, a tap
/// there must name that sentence.
@Suite("Tapping real prose")
@MainActor
struct RealProseTapTests {
    static let sentences = [
        "They had been flying apart, but they huddled close to Peter now. ",
        "His careless manner had gone at last, his eyes were sparkling, and a tingle went through them every time they touched his body. ",
        "They were now over the fearsome island, flying so low that sometimes a tree grazed their feet. ",
        "Nothing horrid was visible in the air, yet their progress had become slow and laboured. ",
        "Sometimes they hung in the air until Peter had beaten on it with his fists. ",
    ]

    /// Ids on the spans and none on the paragraph, exactly as Storyteller writes
    /// it — which is what makes each paragraph a single multi-line fragment.
    static func chapter(style: ReaderStyle, width: CGFloat = 300) throws -> ChapterLayout {
        var body = ""
        var n = 0
        for _ in 0 ..< 5 {
            var spans = ""
            for sentence in sentences {
                spans += "<span id=\"s\(n)\">\(sentence)</span>"
                n += 1
            }
            body += "<p>\(spans)</p>"
        }
        // An indented block carries headIndent and firstLineHeadIndent, which
        // the line search also has to survive.
        body += "<blockquote><p>"
        for sentence in sentences.prefix(3) {
            body += "<span id=\"q\(n)\">\(sentence)</span>"
            n += 1
        }
        body += "</p></blockquote>"

        let xhtml = "<?xml version=\"1.0\" encoding=\"utf-8\"?><html><body>\(body)</body></html>"
        let result = try HTMLContentParser(style: style)
            .parse(xhtml: Data(xhtml.utf8), baseHref: "chapter.xhtml")
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: width, height: 2000))
        return layout
    }

    /// Every rectangle the highlight would draw, tapped at its centre.
    ///
    /// Deliberately not a sample. The old test took the single widest rect per
    /// fragment, skipped anything under 30pt and stopped after twelve — which a
    /// bug sparing the opening line of each paragraph passes untouched.
    static func audit(_ layout: ChapterLayout) -> (checked: Int, wrong: Int, missed: [String]) {
        var checked = 0
        var wrong = 0
        var missed: [String] = []
        for id in layout.fragmentRanges.keys.sorted() {
            guard let page = layout.page(containingFragment: id) else { continue }
            var sawOne = false
            for rect in layout.highlightRects(forFragment: id, on: page) {
                // A wrapped sentence leaves a sliver at either end of a line
                // where a midpoint genuinely belongs to a neighbour. Every
                // fragment still contributes its full-width lines.
                guard rect.width >= 16, rect.height >= 4 else { continue }
                sawOne = true
                checked += 1
                let point = CGPoint(x: rect.midX, y: rect.midY)
                if layout.fragmentID(at: point, on: page) != id { wrong += 1 }
            }
            if !sawOne { missed.append(id) }
        }
        return (checked, wrong, missed)
    }

    @Test("every point the highlight covers resolves back to its own sentence",
          arguments: [ReaderStyle.LineSpacing.tight, .normal, .roomy])
    func inverseOfTheHighlight(_ spacing: ReaderStyle.LineSpacing) throws {
        var style = ReaderStyle()
        style.lineSpacing = spacing
        let layout = try Self.chapter(style: style)
        let (checked, wrong, _) = Self.audit(layout)

        #expect(checked > 60, "the fixture should offer plenty of points; got \(checked)")
        #expect(wrong == 0, "\(wrong) of \(checked) points resolved to the wrong sentence or to nothing")
    }

    @Test("justified text, where hyphenation and stretched spaces move every line")
    func justified() throws {
        var style = ReaderStyle()
        style.justified = true
        let layout = try Self.chapter(style: style)
        let (checked, wrong, _) = Self.audit(layout)
        #expect(wrong == 0, "\(wrong) of \(checked) points resolved elsewhere when justified")
    }

    @Test("every sentence is reachable, not merely most of them")
    func coverage() throws {
        let layout = try Self.chapter(style: ReaderStyle())
        let (_, _, missed) = Self.audit(layout)
        #expect(missed.isEmpty, "no rectangle wide enough to tap for: \(missed.sorted())")
    }

    /// The reported symptom, stated as a test: a tap deep inside a paragraph.
    ///
    /// The sentences that kept working were the ones on a paragraph's opening
    /// line. This asserts the others.
    @Test("a tap on the last line of a long paragraph names the sentence there")
    func deepInsideAParagraph() throws {
        let layout = try Self.chapter(style: ReaderStyle())
        let page = try #require(layout.pages.first)
        // The fifth sentence of the first paragraph — well past the first line.
        let id = "s4"
        let rects = layout.highlightRects(forFragment: id, on: page)
        let rect = try #require(rects.max(by: { $0.width < $1.width }))
        #expect(layout.fragmentID(at: CGPoint(x: rect.midX, y: rect.midY), on: page) == id)
    }
}


/// Which id a tap is allowed to answer with, and what happens when the point
/// owns none.
///
/// Element ids are not all sentences. A chapter heading has one, a Gutenberg
/// page anchor has one, and plenty of publishers put one on every `<p>`. The
/// characters between and around sentences — a paragraph's trailing newline,
/// the space after a short last line — frequently belong to *no* narrated
/// fragment at all. Answering "nothing" there is a silent refusal: the reader
/// pointed at a page and the book did not respond, with no way to tell whether
/// the tap even registered.
@Suite("Resolving a tap to something usable")
@MainActor
struct UsableFragmentTests {
    /// A publisher's shape rather than Gutenberg's: the paragraph carries an id
    /// of its own, wrapping the sentence spans.
    static func chapter() throws -> ChapterLayout {
        var spans = ""
        for (i, sentence) in RealProseTapTests.sentences.enumerated() {
            spans += "<span id=\"s\(i)\">\(sentence)</span>"
        }
        let xhtml = "<html><body><p id=\"para1\">\(spans)</p>"
            + "<p id=\"para2\"><span id=\"s9\">A short closing line.</span></p></body></html>"
        let result = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: Data(xhtml.utf8), baseHref: "c.xhtml")
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 300, height: 2000))
        return layout
    }

    static let narrated: (String) -> Bool = { $0.hasPrefix("s") }

    @Test("a paragraph wrapper cannot shadow the sentence inside it")
    func wrapperNeverWins() throws {
        let layout = try Self.chapter()
        let page = try #require(layout.pages.first)
        // Both ids are recorded; only the spans are narrated.
        #expect(layout.fragmentRanges["para1"] != nil)

        var checked = 0
        for id in layout.fragmentRanges.keys.sorted() where Self.narrated(id) {
            for rect in layout.highlightRects(forFragment: id, on: page)
            where rect.width >= 16 {
                checked += 1
                let got = layout.fragmentID(
                    at: CGPoint(x: rect.midX, y: rect.midY), on: page, matching: Self.narrated)
                #expect(got == id)
            }
        }
        #expect(checked > 4)
    }

    @Test("a tap past the end of a short last line still finds that line's sentence")
    func pastTheEndOfALine() throws {
        let layout = try Self.chapter()
        let page = try #require(layout.pages.first)
        // The final paragraph is one short line; aim well to the right of where
        // its text stops. Those characters belong to the paragraph, not to any
        // sentence, so the enclosing search finds nothing.
        let rect = try #require(layout.highlightRects(forFragment: "s9", on: page).first)
        let pastTheText = CGPoint(x: 295, y: rect.midY)

        #expect(layout.fragmentID(at: pastTheText, on: page, matching: Self.narrated) == "s9",
                "a tap on the same line as a sentence should reach it")
    }

    @Test("nothing usable on the page means nothing, rather than a wrong answer")
    func noUsableFragments() throws {
        let layout = try Self.chapter()
        let page = try #require(layout.pages.first)
        let rect = try #require(layout.highlightRects(forFragment: "s0", on: page).first)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        #expect(layout.fragmentID(at: point, on: page, matching: { _ in false }) == nil)
    }

    @Test("the same point always resolves to the same id")
    func deterministic() throws {
        // `Dictionary.filter` has no defined iteration order, so a tie between
        // two equal-length ranges used to be resolved arbitrarily.
        let layout = try Self.chapter()
        let page = try #require(layout.pages.first)
        let rect = try #require(layout.highlightRects(forFragment: "s2", on: page).first)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let answers = Set((0 ..< 40).map { _ in
            layout.fragmentID(at: point, on: page, matching: Self.narrated) ?? "nil"
        })
        #expect(answers.count == 1, "resolved to \(answers.sorted()) across repeated calls")
    }

    @Test("the nearest answer never reaches off the page the reader is looking at")
    func fallbackStaysOnThePage() throws {
        // Several paragraphs, paginated small, so a tap low on one page has
        // text from the *next* page nearby in character terms but not on screen.
        var body = ""
        var n = 0
        for _ in 0 ..< 8 {
            body += "<p id=\"p\(n)\">"
            for sentence in RealProseTapTests.sentences {
                body += "<span id=\"s\(n)\">\(sentence)</span>"
                n += 1
            }
            body += "</p>"
        }
        let result = try HTMLContentParser(style: ReaderStyle())
            .parse(xhtml: Data("<html><body>\(body)</body></html>".utf8), baseHref: "c.xhtml")
        let layout = ChapterLayout(text: result.text, fragmentRanges: result.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 300, height: 320))
        #expect(layout.pages.count > 2, "the fixture should paginate")

        for page in layout.pages.dropFirst().prefix(3) {
            // Bottom-right of the page: past the end of the last line, which is
            // exactly where the enclosing search comes up empty.
            let point = CGPoint(x: 295, y: page.height - 4)
            guard let id = layout.fragmentID(at: point, on: page, matching: Self.narrated),
                  let range = layout.fragmentRanges[id]
            else { continue }
            #expect(NSIntersectionRange(range, page.characterRange).length > 0,
                    "\(id) is not on page \(page.index)")
        }
    }

    @Test("the unfiltered form still answers with the innermost id")
    func defaultPredicateUnchanged() throws {
        let layout = try Self.chapter()
        let page = try #require(layout.pages.first)
        let rect = try #require(layout.highlightRects(forFragment: "s1", on: page).first)
        // No predicate: the sentence still wins over its paragraph, because it
        // is the shorter range.
        #expect(layout.fragmentID(at: CGPoint(x: rect.midX, y: rect.midY), on: page) == "s1")
    }
}
