import CoreGraphics
import Foundation
import Testing

@testable import IssaRender

/// What a page says when it is read aloud.
@Suite("Speaking a page")
@MainActor
struct SpokenPageTests {
    func layout(_ text: NSAttributedString, width: CGFloat = 320, height: CGFloat = 200) -> ChapterLayout {
        let layout = ChapterLayout(text: text, fragmentRanges: [:])
        layout.layout(pageSize: CGSize(width: width, height: height))
        return layout
    }

    /// An illustration is an object-replacement character, which no screen
    /// reader can pronounce. Without its alt text a full-page plate is a page
    /// with one silent glyph on it.
    @Test("an illustration is spoken as its alternative text")
    func imageAlt() {
        let style = ReaderStyle()
        let text = NSMutableAttributedString(
            string: "Before. ", attributes: [.font: style.bodyFont()])
        text.append(NSAttributedString(
            string: "\u{FFFC}",
            attributes: [.font: style.bodyFont(), .issaImageAlt: "Peter flying over London"]))
        text.append(NSAttributedString(string: " After.", attributes: [.font: style.bodyFont()]))

        let laid = layout(text)
        let page = try! #require(laid.pages.first)
        let spoken = laid.spokenText(on: page)
        #expect(spoken.contains("Peter flying over London"))
        #expect(!spoken.contains("\u{FFFC}"))
    }

    /// A book that gives no alt text still must not leave a silent gap in the
    /// middle of a sentence.
    @Test("an illustration with no alt text is still announced")
    func imageWithoutAlt() {
        let style = ReaderStyle()
        let text = NSMutableAttributedString(
            string: "Before. \u{FFFC} After.", attributes: [.font: style.bodyFont()])
        let laid = layout(text)
        let page = try! #require(laid.pages.first)
        let spoken = laid.spokenText(on: page)
        #expect(spoken.contains("Image."))
        #expect(!spoken.contains("\u{FFFC}"))
    }

    /// The spoken page must not include a paragraph that began on an earlier
    /// one: a sighted reader is not looking at it.
    @Test("a page speaks only what is painted on it")
    func paintedOnly() {
        let style = ReaderStyle()
        let body = (1 ... 40)
            .map { "Sentence number \($0) of the chapter, long enough to wrap a line or two." }
            .joined(separator: "\n\n")
        let laid = layout(NSAttributedString(string: body, attributes: [.font: style.bodyFont()]))
        #expect(laid.pages.count > 1)

        for page in laid.pages {
            let painted = laid.paintedCharacterRange(for: page)
            #expect(painted.location >= page.characterRange.location)
            #expect(NSMaxRange(painted) <= NSMaxRange(page.characterRange) + 1)
        }
        // Consecutive pages must not both speak the same opening words.
        let first = laid.spokenText(on: laid.pages[0])
        let second = laid.spokenText(on: laid.pages[1])
        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
        #expect(first != second)
    }

    @Test("a page with nothing on it speaks nothing rather than crashing")
    func emptyPage() {
        let laid = layout(NSAttributedString(string: ""))
        guard let page = laid.pages.first else { return }
        #expect(laid.spokenText(on: page).isEmpty)
    }
}
