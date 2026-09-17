import Foundation
import Testing

@testable import IssaEPUB

/// The CSS subset, and its edges.
///
/// The edges are the point: a reader that reads *some* CSS has to be exact
/// about which, because a rule half-applied is invisible to the person holding
/// the book. Every case here that expects nothing is as deliberate as the ones
/// that expect something.
@Suite("What a book's stylesheet asks for")
struct EPUBStyleSheetTests {
    func sheet(_ css: String) -> EPUBStyleSheet {
        var sheet = EPUBStyleSheet()
        sheet.add(css: css)
        return sheet
    }

    @Test("a class that says italic makes its paragraph italic")
    func classItalic() {
        // The shipped bug, in one line: this is how a trade ebook marks a
        // passage of italic dialogue, and it is not <em>.
        let sheet = sheet(".class_s5T-0 {font-style: italic; margin-bottom: 0}")
        let found = sheet.declarations(tag: "p", classes: "class_s5T-0", identifier: nil)
        #expect(found.italic == true)
    }

    @Test("a class the element does not carry says nothing")
    func unrelatedClass() {
        let sheet = sheet(".italic {font-style: italic}")
        #expect(sheet.declarations(tag: "p", classes: "roman", identifier: nil).italic == nil)
    }

    @Test("one element, several classes")
    func severalClasses() {
        let sheet = sheet(".a {font-style: italic} .b {font-weight: bold}")
        let found = sheet.declarations(tag: "p", classes: "a b", identifier: nil)
        #expect(found.italic == true)
        #expect(found.bold == true)
    }

    @Test("a class beats a tag, and an id beats a class")
    func specificity() {
        let sheet = sheet("""
        #here {text-align: right}
        .quiet {text-align: center}
        p {text-align: left}
        """)
        #expect(sheet.declarations(tag: "p", classes: nil, identifier: nil).alignment == .left)
        #expect(sheet.declarations(tag: "p", classes: "quiet", identifier: nil).alignment == .center)
        #expect(
            sheet.declarations(tag: "p", classes: "quiet", identifier: "here").alignment == .right)
    }

    @Test("equally specific rules break the tie by order")
    func sourceOrder() {
        let sheet = sheet(".a {font-style: italic} .a {font-style: normal}")
        #expect(sheet.declarations(tag: "p", classes: "a", identifier: nil).italic == false)
    }

    @Test("the element's own style attribute beats every rule")
    func inlineStyleWins() {
        let sheet = sheet("#loud {font-style: italic}")
        let found = sheet.declarations(
            tag: "p", classes: nil, identifier: "loud", inlineStyle: "font-style: normal")
        #expect(found.italic == false)
    }

    @Test("tag.class matches only that tag carrying that class")
    func tagAndClass() {
        let sheet = sheet("p.lead {font-weight: bold}")
        #expect(sheet.declarations(tag: "p", classes: "lead", identifier: nil).bold == true)
        #expect(sheet.declarations(tag: "div", classes: "lead", identifier: nil).bold == nil)
        #expect(sheet.declarations(tag: "p", classes: nil, identifier: nil).bold == nil)
    }

    @Test("the universal selector reaches everything")
    func universal() {
        let sheet = sheet("* {text-align: justify}")
        #expect(sheet.declarations(tag: "div", classes: nil, identifier: nil).alignment == .justify)
    }

    /// A selector this reader cannot evaluate must match *nothing*. Matching the
    /// last simple part of it instead — the obvious shortcut — would apply a
    /// rule meant for a footnote to every paragraph in the chapter.
    @Test("a selector beyond the subset is ignored rather than approximated")
    func unsupportedSelectors() {
        for selector in [
            "div p", "div > p", "p + p", "p ~ p", "p:first-child", "p[data-x]", ".a.b",
        ] {
            let sheet = sheet("\(selector) {font-style: italic}")
            #expect(
                sheet.declarations(tag: "p", classes: "a b", identifier: nil).italic == nil,
                "\(selector) should match nothing")
        }
    }

    @Test("a media query's rules are skipped whole")
    func mediaQuery() {
        // Skipped, not misread: the closing brace of the inner rule must not be
        // taken for the end of the block, or the next rule in the sheet is
        // parsed with "}" as part of its selector.
        let sheet = sheet("""
        @media (min-width: 40em) { p {font-style: italic} }
        .after {font-weight: bold}
        """)
        #expect(sheet.declarations(tag: "p", classes: nil, identifier: nil).italic == nil)
        #expect(sheet.declarations(tag: "p", classes: "after", identifier: nil).bold == true)
    }

    @Test("an @font-face block is left to the font resolver")
    func fontFaceIgnored() {
        let sheet = sheet("""
        @font-face {font-family: AGaramondPro; font-style: italic; src: url(r.otf)}
        p {font-style: normal}
        """)
        // The @font-face's `font-style: italic` describes the *file*, not the
        // text. Read as a rule it would set every page in italic.
        #expect(sheet.declarations(tag: "p", classes: nil, identifier: nil).italic == false)
    }

    @Test("a comment cannot corrupt the rule beside it")
    func comments() {
        let sheet = sheet("""
        /* the quiet ones */ .quiet {font-style: /* here */ italic}
        """)
        #expect(sheet.declarations(tag: "p", classes: "quiet", identifier: nil).italic == true)
    }

    @Test("indents resolve as a fraction of the column or a multiple of the type")
    func indentLengths() {
        let sheet = sheet(".a {text-indent: 4.688%} .b {text-indent: 1.5em} .c {text-indent: 0}")
        #expect(
            sheet.declarations(tag: "p", classes: "a", identifier: nil).textIndent
                == .fraction(0.04688))
        #expect(sheet.declarations(tag: "p", classes: "b", identifier: nil).textIndent == .ems(1.5))
        #expect(
            sheet.declarations(tag: "p", classes: "c", identifier: nil).textIndent == .fraction(0))
    }

    /// Honouring `font-size: 11pt` would pin the page to the publisher's idea of
    /// size and leave the reader's own Text size control doing nothing — on
    /// every InDesign-exported book, which is most of them.
    @Test("an absolute size is refused; a relative one is a multiplier")
    func onlyRelativeSizes() {
        let sheet = sheet(".pt {font-size: 11pt} .px {font-size: 16px} .em {font-size: 1.3em}")
        #expect(sheet.declarations(tag: "p", classes: "pt", identifier: nil).fontScale == nil)
        #expect(sheet.declarations(tag: "p", classes: "px", identifier: nil).fontScale == nil)
        #expect(sheet.declarations(tag: "p", classes: "em", identifier: nil).fontScale == 1.3)
    }

    @Test("a numeric weight is bold from semibold up")
    func numericWeights() {
        #expect(EPUBStyleSheet.isBold("700") == true)
        #expect(EPUBStyleSheet.isBold("600") == true)
        #expect(EPUBStyleSheet.isBold("500") == false)
        #expect(EPUBStyleSheet.isBold("bold") == true)
        #expect(EPUBStyleSheet.isBold("normal") == false)
        #expect(EPUBStyleSheet.isBold("inherit") == nil)
    }

    /// Both would change which characters are rendered, and every fragment
    /// range, passage offset and saved highlight is measured in those.
    @Test("colour and text-transform are never read")
    func refusedProperties() {
        let sheet = sheet(".a {color: #0000fe; text-transform: uppercase; font-style: italic}")
        let found = sheet.declarations(tag: "p", classes: "a", identifier: nil)
        // Only the one property that can be honoured survives.
        #expect(found.italic == true)
        #expect(found.alignment == nil)
        #expect(found.fontScale == nil)
    }

    @Test("underline is read, and turning it off is read too")
    func decoration() {
        let sheet = sheet(".a {text-decoration: underline} .b {text-decoration: none}")
        #expect(sheet.declarations(tag: "a", classes: "a", identifier: nil).underlined == true)
        #expect(sheet.declarations(tag: "a", classes: "b", identifier: nil).underlined == false)
    }

    @Test("a family is read for the font resolver, quotes and all")
    func families() {
        let sheet = sheet(".class-1 {font-family: \"AGaramond Pro\", serif}")
        #expect(
            sheet.declarations(tag: "body", classes: "class-1", identifier: nil).families
                == ["agaramond pro", "serif"])
    }

    @Test("a sheet with nothing this reader understands is empty")
    func empty() {
        #expect(sheet("p {margin-top: 0; page-break-before: avoid}").isEmpty)
        #expect(EPUBStyleSheet().isEmpty)
    }

    @Test("a truncated sheet does not hang or throw")
    func truncated() {
        // Real books ship broken CSS, and an unterminated block must not spin.
        #expect(sheet(".a {font-style: italic").isEmpty)
        #expect(sheet("/* unterminated").isEmpty)
        #expect(!sheet(".a {font-style: italic} .b {").isEmpty)
    }
}
