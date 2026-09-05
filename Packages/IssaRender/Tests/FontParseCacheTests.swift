import CoreGraphics
import Foundation
import IssaUI
import Testing

@testable import IssaRender

/// The parser's font cache answers the question it was asked.
///
/// `attributes(for:)` now resolves each distinct face once per chapter rather
/// than once per attribute run, because `bodyFont` runs a CoreText descriptor
/// match and a marked-up chapter asks thousands of times for one of about four
/// answers. A cache like that has exactly one failure mode worth testing: a key
/// that does not distinguish two requests, so a run is set in the face the
/// previous one asked for. Every case below is a pair that must not collide,
/// asserted through the parser's own output rather than against the cache.
///
/// Not `.serialized`. An earlier version carried the trait and said it was what
/// stopped a CoreText deadlock; it was not — the trait serialises cases within
/// one suite, not suites against each other. The guard is `fontMatchingLock`
/// in `ReaderStyle.swift`, around every descriptor match.
@Suite("Fonts within one parse")
struct FontParseCacheTests {
    init() { IssaFonts.register() }

    /// Alternating so a cache that returned the previous answer would be caught
    /// on the second plain run, not merely on the first emphasised one.
    static let markup = """
    <html><body>
    <h1>A Heading</h1>
    <p>Plain. <em>Emphasis.</em> Plain again. <strong>Strong.</strong> Plain once more.</p>
    <h1>Another Heading</h1>
    <p>Closing plain text.</p>
    </body></html>
    """

    static func parse() throws -> NSAttributedString {
        var style = ReaderStyle()
        style.typeface = .bundled(ReaderStyle.defaultFamily)
        style.fontSize = 18
        let data = try #require(markup.data(using: .utf8))
        return try HTMLContentParser(style: style).parse(xhtml: data, baseHref: "ch.xhtml").text
    }

    static func font(under word: String, in text: NSAttributedString) throws -> PlatformFont {
        let range = (text.string as NSString).range(of: word)
        try #require(range.location != NSNotFound, "\"\(word)\" is not in the parsed text")
        return try #require(text.attribute(.font, at: range.location, effectiveRange: nil) as? PlatformFont)
    }

    @Test("emphasis is set in italic and the text after it is not")
    func italicIsPartOfTheKey() throws {
        let text = try Self.parse()
        #expect(try Self.font(under: "Emphasis", in: text).isItalic)
        #expect(try !Self.font(under: "Plain again", in: text).isItalic,
                "the run after an emphasis kept the italic face")
        #expect(try !Self.font(under: "Plain.", in: text).isItalic)
    }

    @Test("strong is set in bold and the text after it is not")
    func boldIsPartOfTheKey() throws {
        let text = try Self.parse()
        let strong = try Self.font(under: "Strong", in: text)
        let after = try Self.font(under: "Plain once more", in: text)
        #expect(strong.fontName != after.fontName,
                "\(strong.fontName) was used for both the strong run and the plain one after it")
        #expect(try Self.font(under: "Plain.", in: text).fontName == after.fontName,
                "two plain runs either side of the markup must be set identically")
    }

    /// The heading scale multiplies the size, so a heading and body text at the
    /// same declared size are different requests — and the *second* heading is
    /// the one that proves the cache is keyed and not merely first-write-wins.
    @Test("the heading scale is part of the key")
    func scaleIsPartOfTheKey() throws {
        let text = try Self.parse()
        let heading = try Self.font(under: "A Heading", in: text)
        let second = try Self.font(under: "Another Heading", in: text)
        let body = try Self.font(under: "Plain.", in: text)
        #expect(heading.pointSize > body.pointSize)
        #expect(second.pointSize == heading.pointSize,
                "the second heading came back at \(second.pointSize) rather than \(heading.pointSize)")
    }

    /// A cache held for the length of one parse and no longer. Two parsers,
    /// two styles, two answers — a cache shared between them would give the
    /// second parse the first's face.
    @Test("one parse's fonts do not reach the next")
    func cacheDoesNotOutliveTheParse() throws {
        let data = try #require(Self.markup.data(using: .utf8))
        var small = ReaderStyle()
        small.fontSize = 14
        var large = ReaderStyle()
        large.fontSize = 28

        let a = try HTMLContentParser(style: small).parse(xhtml: data, baseHref: "ch.xhtml").text
        let b = try HTMLContentParser(style: large).parse(xhtml: data, baseHref: "ch.xhtml").text
        #expect(try Self.font(under: "Plain.", in: a).pointSize == 14)
        #expect(try Self.font(under: "Plain.", in: b).pointSize == 28)
    }
}

private extension PlatformFont {
    var isItalic: Bool {
        #if canImport(UIKit)
        fontDescriptor.symbolicTraits.contains(.traitItalic)
        #else
        fontDescriptor.symbolicTraits.contains(.italic)
        #endif
    }
}
