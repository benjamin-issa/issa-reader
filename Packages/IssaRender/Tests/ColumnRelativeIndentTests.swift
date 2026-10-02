import CoreGraphics
import Foundation
import IssaEPUB
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@testable import IssaRender

/// A chapter parsed the way the reader parses one: a linked sheet, and a
/// column width that a percentage resolves against.
private func parseChapter(
    _ body: String, css: String, columnWidth: CGFloat, loadImage: ((String) -> PlatformImage?)? = nil,
) throws -> HTMLContentParser.Result {
    var sheet = EPUBStyleSheet()
    sheet.add(css: css)
    let html = Data("""
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><link rel="stylesheet" type="text/css" href="style.css"/></head>
    \(body)
    </html>
    """.utf8)
    return try HTMLContentParser(
        style: ReaderStyle(), maxImageWidth: columnWidth, columnWidth: columnWidth,
        loadImage: loadImage,
        loadStyleSheet: { $0 == "style.css" ? sheet : nil },
    ).parse(xhtml: html, baseHref: "c.xhtml")
}

private func paragraphStyle(_ text: NSAttributedString, at index: Int) throws -> NSParagraphStyle {
    try #require(text.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle)
}

/// An indent the width of the column pushes the paragraph's whole first line
/// into a zero-width fragment at the right edge, where it is clipped: the
/// first line of every such paragraph was invisible.
@Suite("A book cannot indent a first line off the page")
struct IndentBoundTests {
    @Test("an over-wide or infinite indent is held to half the column", arguments: [
        // Parses to +infinity, which is not a length: ignored, as NaN is.
        ("1e400em", 0),
        ("100%", 160),
        // 450pt at the default 18pt: a large indent is still an indent.
        ("25em", 160),
    ] as [(String, CGFloat)])
    func boundedAtHalfTheColumn(_ indent: String, _ expected: CGFloat) throws {
        let result = try parseChapter(
            "<body><p class=\"wide\">A first line that should be seen.</p></body>",
            css: ".wide {text-indent: \(indent)}", columnWidth: 320)
        let first = try paragraphStyle(result.text, at: 0).firstLineHeadIndent
        #expect(first.isFinite)
        #expect(first <= 160, "\(indent) gave \(first)")
        #expect(first == expected, "\(indent) gave \(first)")
    }

    @Test("the bound is past any quotation's own indent, not instead of it")
    func boundedInsideABlockquote() throws {
        let result = try parseChapter(
            "<body class=\"wide\"><blockquote><p>Quoted.</p></blockquote></body>",
            css: ".wide {text-indent: 100%}", columnWidth: 320)
        let paragraph = try paragraphStyle(result.text, at: 0)
        #expect(paragraph.headIndent > 0)
        #expect(paragraph.firstLineHeadIndent == paragraph.headIndent + 160)
    }

    @Test("an ordinary indent is untouched")
    func ordinaryIndent() throws {
        let result = try parseChapter(
            "<body><p class=\"i\">Text.</p></body>", css: ".i {text-indent: 1.5em}",
            columnWidth: 320)
        #expect(try paragraphStyle(result.text, at: 0).firstLineHeadIndent == 27)
    }
}

/// A percentage indent is a fraction of the column, and the column changes on
/// rotation, a split-view drag or a Mac window resize — none of which parses
/// the chapter again. `ReaderModel.resize` → `relayoutCurrentChapter` →
/// `ChapterLayout.layout(pageSize:)` is the whole of that path.
@Suite("A percentage indent follows the column")
@MainActor
struct ColumnRelativeIndentTests {
    @Test("a 5% indent parsed at 300pt and laid out at 600pt is 30pt")
    func followsAWiderColumn() throws {
        let parsed = try parseChapter(
            "<body class=\"text\"><p>First paragraph.</p><p>Second paragraph.</p></body>",
            css: ".text {text-indent: 5%}", columnWidth: 300)
        #expect(try paragraphStyle(parsed.text, at: 0).firstLineHeadIndent == 15)

        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 600, height: 800))
        #expect(try paragraphStyle(layout.attributedText, at: 0).firstLineHeadIndent == 30)
        let second = (layout.attributedText.string as NSString).range(of: "Second")
        #expect(
            try paragraphStyle(layout.attributedText, at: second.location).firstLineHeadIndent == 30)

        // And back again, on the same layout.
        layout.layout(pageSize: CGSize(width: 300, height: 800))
        #expect(try paragraphStyle(layout.attributedText, at: 0).firstLineHeadIndent == 15)
        // Only attributes moved: every offset a highlight or a position is
        // measured in is the one the parser produced.
        #expect(layout.attributedText.string == parsed.text.string)
    }

    @Test("the laid-out first line really moves, not only the attribute")
    func theGlyphsMove() throws {
        let parsed = try parseChapter(
            "<body class=\"text\"><p id=\"p\">Indented paragraph text.</p></body>",
            css: ".text {text-indent: 10%}", columnWidth: 300)
        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 300, height: 800))
        let narrow = try #require(layout.pages.first)
        let before = try #require(layout.highlightRects(forFragment: "p", on: narrow).first)
        layout.layout(pageSize: CGSize(width: 600, height: 800))
        let wide = try #require(layout.pages.first)
        let after = try #require(layout.highlightRects(forFragment: "p", on: wide).first)
        #expect(abs(before.minX - 30) < 1)
        #expect(abs(after.minX - 60) < 1)
    }

    @Test("an em indent clamped to a wide column is clamped again for a narrow one")
    func emIndentBoundedAgain() throws {
        // 25em at the default 18pt is 450pt: allowed on a 1000pt column, but on
        // a 320pt one it would hide the first line.
        let parsed = try parseChapter(
            "<body><p class=\"wide\">A paragraph.</p></body>",
            css: ".wide {text-indent: 25em}", columnWidth: 1000)
        #expect(try paragraphStyle(parsed.text, at: 0).firstLineHeadIndent == 450)
        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 320, height: 800))
        #expect(try paragraphStyle(layout.attributedText, at: 0).firstLineHeadIndent == 160)
        layout.layout(pageSize: CGSize(width: 1000, height: 800))
        #expect(try paragraphStyle(layout.attributedText, at: 0).firstLineHeadIndent == 450)
    }

    @Test("a plate and an unindented paragraph are left alone")
    func othersUntouched() throws {
        let plate = PlatformImage.solid(width: 40, height: 40)
        let parsed = try parseChapter(
            """
            <body class="text"><p class="flush">Flush.</p><p><img src="i.png"/></p></body>
            """,
            css: ".text {text-indent: 5%} .flush {text-indent: 0}", columnWidth: 300,
            loadImage: { _ in plate })
        let layout = ChapterLayout(text: parsed.text, fragmentRanges: parsed.fragmentRanges)
        layout.layout(pageSize: CGSize(width: 600, height: 800))
        #expect(try paragraphStyle(layout.attributedText, at: 0).firstLineHeadIndent == 0)
        let image = (layout.attributedText.string as NSString).range(of: "\u{FFFC}")
        #expect(image.location != NSNotFound)
        #expect(
            try paragraphStyle(layout.attributedText, at: image.location).firstLineHeadIndent == 0)
    }
}
