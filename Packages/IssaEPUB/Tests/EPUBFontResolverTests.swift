import Foundation
import Testing

@testable import IssaEPUB

/// "The publisher's font" as an option beside the app's own faces.
///
/// The resolver reads two things out of a book's CSS and nothing else. These
/// tests are as much about what it declines to do as what it does: every
/// assertion that it ignores a rule is deliberate, because the alternative is
/// a cascade the renderer has nothing to apply.
@Suite("The publisher's font")
struct EPUBFontResolverTests {
    func package(_ fixture: String) throws -> EPUBPackage {
        let url = try #require(Bundle.module.url(
            forResource: "Fixtures/\(fixture)", withExtension: "epub"))
        return try EPUBPackage.open(url: url)
    }

    // MARK: - Finding it

    /// Bulletproof `@font-face` syntax, which publishers actually ship. The
    /// first fix stripped the query from `format` alone, so the face was
    /// reported `.found` for a path still ending in `?` and then failed
    /// silently in `archive.read` — worse than the honest `.unreadableFormat`
    /// it replaced.
    @Test("a query string is not part of the path")
    func queryIsStrippedFromThePath() throws {
        let css = "@font-face { font-family: Charis; src: url('fonts/Charis.otf?#iefix'); }"
        let face = try #require(EPUBFontResolver.fontFaces(in: css, relativeTo: "OEBPS/styles.css").first)
        #expect(!face.path.contains("?"), "the path \(face.path) is not one the archive holds")
        #expect(face.path.hasSuffix("fonts/Charis.otf"))
        #expect(face.format == "otf")
    }

    @Test("a book that embeds its body face offers it")
    func findsEmbeddedFont() throws {
        guard case let .found(face) = EPUBFontResolver.resolve(in: try package("embedded-font"))
        else { Issue.record("expected a face"); return }
        #expect(face.family == "Publisher Serif")
        #expect(face.path == "OEBPS/fonts/Body.ttf")
        #expect(face.format == "ttf")
    }

    /// The discriminating case: the book embeds a display face *first* and the
    /// text face second. Taking the first `@font-face` would set the whole book
    /// in the drop-cap font, which is what a naive reader of the CSS does.
    @Test("a display face declared first does not win over the body's")
    func prefersBodyFaceOverTheFirstDeclared() throws {
        guard case let .found(face) = EPUBFontResolver.resolve(in: try package("two-fonts"))
        else { Issue.record("expected a face"); return }
        #expect(face.family == "Running Text")
        #expect(face.path == "OEBPS/fonts/Text.ttf")
    }

    /// Gutenberg ships stylesheets and no fonts, which is every book in the
    /// test library — and why this fixture had to be built rather than found.
    @Test("a book with CSS but no font says so")
    func reportsNoEmbeddedFont() throws {
        #expect(EPUBFontResolver.resolve(in: try package("alice"))
            == .unavailable(.noEmbeddedFont))
    }

    // MARK: - Declining, rather than mangling

    /// EPUB 3 permits WOFF and WOFF2. CoreText reads neither, and registering
    /// the bytes anyway produces a face that renders nothing.
    @Test("a WOFF2 face is refused, and names the format")
    func refusesWOFF() throws {
        #expect(EPUBFontResolver.resolve(in: try package("woff-font"))
            == .unavailable(.unreadableFormat("woff2")))
    }

    /// The publisher scrambled the first 1040 bytes so the font cannot be
    /// lifted out of the book. This app does not deobfuscate, so what is on
    /// disk is not a font.
    @Test("an obfuscated face is refused rather than registered as garbage")
    func refusesObfuscated() throws {
        #expect(EPUBFontResolver.resolve(in: try package("obfuscated-font"))
            == .unavailable(.obfuscated))
    }

    // MARK: - The reading itself

    @Test("the family the body asks for is the one chosen")
    func prefersTheBodyFamily() {
        let css = """
        @font-face { font-family: "Ornament"; src: url(orn.otf); }
        @font-face { font-family: "Text"; src: url(text.otf); }
        body { font-family: "Text", serif; }
        """
        let faces = EPUBFontResolver.fontFaces(in: css, relativeTo: "OEBPS/s.css")
        #expect(faces.count == 2)
        #expect(EPUBFontResolver.bodyFontFamilies(in: css).first == "Text")
    }

    @Test("a book that embeds exactly one face means it for the text")
    func fallsBackToTheOnlyFace() throws {
        // `embedded-font` names its family in `body`; the single-face rule is
        // what covers a book whose body rule is missing or unparsed.
        let css = "@font-face { font-family: Solo; src: url(solo.otf); }"
        #expect(EPUBFontResolver.bodyFontFamilies(in: css).isEmpty)
        #expect(EPUBFontResolver.fontFaces(in: css, relativeTo: "s.css").count == 1)
    }

    @Test("a class rule is not the body, and is ignored")
    func ignoresClassSelectors() {
        let css = """
        body { font-family: "Text"; }
        p.drop { font-family: "Ornament"; }
        body.night { font-family: "Never"; }
        """
        #expect(EPUBFontResolver.bodyFontFamilies(in: css) == ["Text"])
    }

    @Test("a grouped selector still counts as the body")
    func readsGroupedSelectors() {
        #expect(EPUBFontResolver.bodyFontFamilies(in: "html, body { font-family: Text; }")
            == ["Text", "Text"])
    }

    @Test("quotes and whitespace in a src are not part of the path")
    func parsesQuotedURL() {
        #expect(EPUBFontResolver.firstURL(in: "url( 'fonts/Body.otf' ) format('opentype')")
            == "fonts/Body.otf")
        #expect(EPUBFontResolver.firstURL(in: #"url("a.otf")"#) == "a.otf")
        #expect(EPUBFontResolver.firstURL(in: "local(Whatever)") == nil)
    }

    @Test("a font path is resolved against the stylesheet, not the root")
    func resolvesRelativeToStylesheet() {
        let css = "@font-face { font-family: X; src: url(../fonts/B.otf); }"
        let faces = EPUBFontResolver.fontFaces(in: css, relativeTo: "OEBPS/css/main.css")
        #expect(faces.first?.path == "OEBPS/fonts/B.otf")
    }

    /// The exact shape mainstream tools emit: an `@charset`, comments between
    /// rules, then the faces and the body rule. Each of those used to glue
    /// itself onto the following selector, and the exact-equality `matches`
    /// then dropped the rule — silently costing the book its body face.
    @Test("comments and at-rules do not cost the rules that follow them")
    func survivesCommentsAndAtRules() {
        let css = """
        @charset "utf-8";
        /* Stylesheet generated for this edition. */
        @font-face { font-family: "Minion Pro"; src: url(fonts/MinionPro.otf); }
        @font-face { font-family: "Display"; src: url(fonts/Display.otf); }
        /* Running text */
        body { font-family: "Minion Pro", serif; }
        """
        let faces = EPUBFontResolver.fontFaces(in: css, relativeTo: "OEBPS/s.css")
        #expect(faces.map(\.family) == ["Minion Pro", "Display"])
        #expect(EPUBFontResolver.bodyFontFamilies(in: css) == ["Minion Pro", "serif"])
    }

    @Test("a comment inside a block does not corrupt its declarations")
    func stripsCommentsInsideBlocks() {
        let css = "body { /* running text */ font-family: /* the face */ \"Text\"; }"
        #expect(EPUBFontResolver.bodyFontFamilies(in: css) == ["Text"])
    }

    @Test("an unterminated comment swallows the rest, the way a browser reads it")
    func unterminatedCommentSwallowsTheRest() {
        let css = "body { font-family: A; } /* trailing body { font-family: B; }"
        #expect(EPUBFontResolver.bodyFontFamilies(in: css) == ["A"])
    }

    /// A stylesheet that fails to parse must not take the book down with it.
    @Test("malformed CSS yields no face rather than throwing")
    func survivesMalformedCSS() {
        #expect(EPUBFontResolver.fontFaces(in: "@font-face { font-family: ", relativeTo: "s.css").isEmpty)
        #expect(EPUBFontResolver.bodyFontFamilies(in: "body {").isEmpty)
        #expect(EPUBFontResolver.blocks(named: "body", in: "}}}{{{").isEmpty)
    }
}
