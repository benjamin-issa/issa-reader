import Foundation
import IssaCore
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
