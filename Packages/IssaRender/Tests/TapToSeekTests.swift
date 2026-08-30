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
