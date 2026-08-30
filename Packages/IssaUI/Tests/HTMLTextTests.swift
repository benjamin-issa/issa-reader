import Foundation
import Testing

@testable import IssaUI

/// Book metadata carries HTML written by people and by scrapers, not by an XML
/// serialiser. These are the shapes that actually turn up.
@Suite("Rendering a description")
struct HTMLTextTests {
    func plain(_ html: String) -> String { HTMLText.plain(html) }

    @Test("tags are removed and the words survive")
    func stripsTags() {
        #expect(plain("<p>It is a truth <i>universally acknowledged</i>.</p>")
            == "It is a truth universally acknowledged.")
    }

    /// The exact fixture on the local server, and the reason the EPUB parser
    /// could not be reused: it throws on both of these.
    @Test("an unescaped ampersand and an unclosed tag do not lose the text")
    func tolerantOfRealMarkup() {
        let text = plain("Plain description with an unescaped & ampersand and an <b>unclosed bold tag")
        #expect(text == "Plain description with an unescaped & ampersand and an unclosed bold tag")
    }

    @Test("a fragment with no root element renders")
    func noRootElement() {
        #expect(plain("A great book. <i>Really.</i>") == "A great book. Really.")
    }

    @Test("entities decode, including numeric and hex")
    func entities() {
        #expect(plain("Austen&#39;s wit &amp; sharpness") == "Austen's wit & sharpness")
        #expect(plain("caf&eacute; &mdash; &#x2026;") == "café — …")
        // A stray ampersand that is not an entity stays exactly as written.
        #expect(plain("Tom & Jerry & Co;") == "Tom & Jerry & Co;")
    }

    @Test("paragraphs become breaks and <br> a single newline")
    func breaks() {
        #expect(plain("<p>One</p><p>Two</p>") == "One\n\nTwo")
        #expect(plain("First<br>Second") == "First\nSecond")
        // No leading break: the first paragraph must not push the text down.
        #expect(!plain("<p>One</p>").hasPrefix("\n"))
    }

    @Test("whitespace collapses the way a browser lays it out")
    func collapsesWhitespace() {
        #expect(plain("Pretty\n   printed\t\tdescription") == "Pretty printed description")
    }

    @Test("unknown tags are dropped rather than shown or thrown")
    func unknownTags() {
        #expect(plain("<span class=\"x\">Kept</span> <madeup>text</madeup>") == "Kept text")
    }

    /// Stray closing tags are common in scraped metadata; they must not
    /// unbalance the style stack and take the rest of the blurb with them.
    @Test("a stray closing tag does not swallow what follows")
    func strayClosingTag() {
        #expect(plain("Start </b></i></p> end") == "Start\n\nend")
    }

    @Test("emphasis and links reach the attributed output")
    func styling() {
        let bold = HTMLText.attributed("<b>Loud</b>")
        #expect(bold.runs.contains { $0.font != nil })

        let linked = HTMLText.attributed("See <a href=\"https://example.com/x\">this</a>.")
        let link = linked.runs.compactMap(\.link).first
        #expect(link?.absoluteString == "https://example.com/x")
        #expect(HTMLText.plain("See <a href=\"https://example.com/x\">this</a>.") == "See this.")
    }

    @Test("a lone angle bracket is text, not a broken tag")
    func unclosedAngleBracket() {
        #expect(plain("5 < 6 and that is that") == "5 < 6 and that is that")
    }

    @Test("empty and whitespace-only input produce nothing")
    func empty() {
        #expect(plain("") == "")
        #expect(plain("<p></p>") == "")
    }
}
