package com.benjaminissa.issareader.epub

import com.benjaminissa.issareader.epub.EpubFontResolver.Resolution
import com.benjaminissa.issareader.epub.EpubFontResolver.Unavailable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `EPUBFontResolverTests.swift`: one class per Swift suite.

/**
 * "The publisher's font" as an option beside the app's own faces.
 *
 * The resolver reads two things out of a book's CSS and nothing else. These
 * tests are as much about what it declines to do as what it does: every
 * assertion that it ignores a rule is deliberate, because the alternative is a
 * cascade the renderer has nothing to apply.
 */
class EpubFontResolverTest {
    private fun found(resolution: Resolution): EpubFontResolver.Face =
        (resolution as? Resolution.Found)?.face ?: throw AssertionError("expected a face, got $resolution")

    // Finding it

    /**
     * Bulletproof `@font-face` syntax, which publishers actually ship. The first
     * fix stripped the query from `format` alone, so the face was reported found
     * for a path still ending in `?` and then failed silently in `archive.read`
     * — worse than the honest `UnreadableFormat` it replaced.
     */
    @Test
    fun queryIsStrippedFromThePath() {
        val css = "@font-face { font-family: Charis; src: url('fonts/Charis.otf?#iefix'); }"
        val face = EpubFontResolver.fontFaces(css, "OEBPS/styles.css").first()
        assertFalse("the path ${face.path} is not one the archive holds", '?' in face.path)
        assertTrue(face.path.endsWith("fonts/Charis.otf"))
        assertEquals("otf", face.format)
    }

    @Test
    fun findsEmbeddedFont() {
        val face = found(EpubFontResolver.resolve(openFixture("embedded-font")))
        assertEquals("Publisher Serif", face.family)
        assertEquals("OEBPS/fonts/Body.ttf", face.path)
        assertEquals("ttf", face.format)
    }

    /**
     * The discriminating case: the book embeds a display face *first* and the
     * text face second. Taking the first `@font-face` would set the whole book
     * in the drop-cap font, which is what a naive reader of the CSS does.
     */
    @Test
    fun prefersBodyFaceOverTheFirstDeclared() {
        val face = found(EpubFontResolver.resolve(openFixture("two-fonts")))
        assertEquals("Running Text", face.family)
        assertEquals("OEBPS/fonts/Text.ttf", face.path)
    }

    /**
     * Gutenberg ships stylesheets and no fonts, which is every book in the test
     * library — and why this fixture had to be built rather than found.
     */
    @Test
    fun reportsNoEmbeddedFont() {
        assertEquals(Resolution.Unavailable(Unavailable.NoEmbeddedFont), EpubFontResolver.resolve(openFixture("alice")))
    }

    // Declining, rather than mangling

    /**
     * EPUB 3 permits WOFF and WOFF2. The platform font loaders read neither,
     * and registering the bytes anyway produces a face that renders nothing.
     */
    @Test
    fun refusesWoff() {
        assertEquals(
            Resolution.Unavailable(Unavailable.UnreadableFormat("woff2")),
            EpubFontResolver.resolve(openFixture("woff-font")),
        )
    }

    /**
     * The publisher scrambled the first 1040 bytes so the font cannot be lifted
     * out of the book. This app does not deobfuscate, so what is on disk is not
     * a font.
     */
    @Test
    fun refusesObfuscated() {
        assertEquals(Resolution.Unavailable(Unavailable.Obfuscated), EpubFontResolver.resolve(openFixture("obfuscated-font")))
    }

    // The reading itself

    @Test
    fun prefersTheBodyFamily() {
        val css = """
            @font-face { font-family: "Ornament"; src: url(orn.otf); }
            @font-face { font-family: "Text"; src: url(text.otf); }
            body { font-family: "Text", serif; }
        """.trimIndent()
        val faces = EpubFontResolver.fontFaces(css, "OEBPS/s.css")
        assertEquals(2, faces.size)
        assertEquals("Text", EpubFontResolver.bodyFontFamilies(css).firstOrNull())
    }

    @Test
    fun fallsBackToTheOnlyFace() {
        // `embedded-font` names its family in `body`; the single-face rule is
        // what covers a book whose body rule is missing or unparsed.
        val css = "@font-face { font-family: Solo; src: url(solo.otf); }"
        assertTrue(EpubFontResolver.bodyFontFamilies(css).isEmpty())
        assertEquals(1, EpubFontResolver.fontFaces(css, "s.css").size)
    }

    @Test
    fun ignoresClassSelectors() {
        val css = """
            body { font-family: "Text"; }
            p.drop { font-family: "Ornament"; }
            body.night { font-family: "Never"; }
        """.trimIndent()
        assertEquals(listOf("Text"), EpubFontResolver.bodyFontFamilies(css))
    }

    @Test
    fun readsGroupedSelectors() {
        assertEquals(listOf("Text", "Text"), EpubFontResolver.bodyFontFamilies("html, body { font-family: Text; }"))
    }

    @Test
    fun parsesQuotedUrl() {
        assertEquals("fonts/Body.otf", EpubFontResolver.firstUrl("url( 'fonts/Body.otf' ) format('opentype')"))
        assertEquals("a.otf", EpubFontResolver.firstUrl("""url("a.otf")"""))
        assertNull(EpubFontResolver.firstUrl("local(Whatever)"))
    }

    @Test
    fun resolvesRelativeToStylesheet() {
        val css = "@font-face { font-family: X; src: url(../fonts/B.otf); }"
        val faces = EpubFontResolver.fontFaces(css, "OEBPS/css/main.css")
        assertEquals("OEBPS/fonts/B.otf", faces.firstOrNull()?.path)
    }

    /**
     * The exact shape mainstream tools emit: an `@charset`, comments between
     * rules, then the faces and the body rule. Each of those used to glue
     * itself onto the following selector, and the exact-equality `matches`
     * then dropped the rule — silently costing the book its body face.
     */
    @Test
    fun survivesCommentsAndAtRules() {
        val css = """
            @charset "utf-8";
            /* Stylesheet generated for this edition. */
            @font-face { font-family: "Minion Pro"; src: url(fonts/MinionPro.otf); }
            @font-face { font-family: "Display"; src: url(fonts/Display.otf); }
            /* Running text */
            body { font-family: "Minion Pro", serif; }
        """.trimIndent()
        val faces = EpubFontResolver.fontFaces(css, "OEBPS/s.css")
        assertEquals(listOf("Minion Pro", "Display"), faces.map { it.family })
        assertEquals(listOf("Minion Pro", "serif"), EpubFontResolver.bodyFontFamilies(css))
    }

    @Test
    fun stripsCommentsInsideBlocks() {
        val css = "body { /* running text */ font-family: /* the face */ \"Text\"; }"
        assertEquals(listOf("Text"), EpubFontResolver.bodyFontFamilies(css))
    }

    /** An unterminated comment swallows the rest, the way a browser reads it. */
    @Test
    fun unterminatedCommentSwallowsTheRest() {
        val css = "body { font-family: A; } /* trailing body { font-family: B; }"
        assertEquals(listOf("A"), EpubFontResolver.bodyFontFamilies(css))
    }

    /** A stylesheet that fails to parse must not take the book down with it. */
    @Test
    fun survivesMalformedCss() {
        assertTrue(EpubFontResolver.fontFaces("@font-face { font-family: ", "s.css").isEmpty())
        assertTrue(EpubFontResolver.bodyFontFamilies("body {").isEmpty())
        assertTrue(EpubFontResolver.blocks("body", "}}}{{{").isEmpty())
    }
}

/**
 * Which member of an embedded family the page is set in, and which others are
 * kept so a word in italic can be italic.
 */
class EmbeddedFamilyTest {
    companion object {
        /**
         * A real book's ordering: the italic face declared first, because that
         * is the order its publisher happened to write them in.
         */
        val css = """
            @font-face {font-family: AGaramondPro; font-style: italic; src: url(font_rsrc14R.otf)}
            @font-face {font-family: AGaramondPro; src: url(font_rsrc14H.otf)}
            @font-face {font-family: AGaramondPro; font-weight: bold; src: url(font_rsrc14B.otf)}
        """.trimIndent()
    }

    @Test
    fun descriptors() {
        val faces = EpubFontResolver.fontFaces(css, "OEBPS/style.css")
        assertEquals(3, faces.size)
        assertTrue(faces[0].isItalic)
        assertFalse(faces[0].isBold)
        assertTrue(!faces[1].isItalic && !faces[1].isBold)
        assertTrue(faces[2].isBold)
    }

    /**
     * Before this, the first rule won — so this book would have been set
     * entirely in italic, with no upright face left for the running text and
     * nothing for the italic trait to add on an emphasised word.
     */
    @Test
    fun uprightWins() {
        val faces = EpubFontResolver.fontFaces(css, "OEBPS/style.css")
        val chosen = EpubFontResolver.upright(faces)
        assertEquals("OEBPS/font_rsrc14H.otf", chosen?.path)
    }

    /**
     * CSS keywords are case-insensitive. `font-weight` was lowercased before it
     * was read and `font-style` was not, so `Italic` read as upright — and
     * declared first, the italic file became the face the page is set in.
     */
    @Test
    fun capitalisedStyle() {
        val faces = EpubFontResolver.fontFaces(
            """
                @font-face { font-family: Body; font-style: Italic; src: url(Body-It.otf) }
                @font-face { font-family: Body; font-style: OBLIQUE; src: url(Body-Ob.otf) }
                @font-face { font-family: Body; font-style: normal; src: url(Body.otf) }
            """.trimIndent(),
            "OEBPS/style.css",
        )
        assertEquals(listOf(true, true, false), faces.map { it.isItalic })
        assertEquals("OEBPS/Body.otf", EpubFontResolver.upright(faces)?.path)
    }

    /** A family with only an italic is still better than no face at all. */
    @Test
    fun onlyItalic() {
        val faces = EpubFontResolver.fontFaces("@font-face {font-family: X; font-style: italic; src: url(i.otf)}", "OEBPS/style.css")
        assertEquals("OEBPS/i.otf", EpubFontResolver.upright(faces)?.path)
    }

    @Test
    fun bodyTag() {
        val attributes = EpubFontResolver.bodyAttributes(
            "<html><head/>\n<body class=\"class-1\" id=\"top\">\n<p>Hi</p></body></html>",
        )
        assertNotNull(attributes)
        assertEquals("class-1", attributes!!["class"])
        assertEquals("top", attributes["id"])
    }

    @Test
    fun bareBodyTag() {
        assertNull(EpubFontResolver.bodyAttributes("<html><body>\n<p>Hi</p></body></html>"))
        assertNull(EpubFontResolver.bodyAttributes("<html><head/></html>"))
    }

    /** Single quotes, and an entity in the value, survive the scan. */
    @Test
    fun awkwardBodyTag() {
        val attributes = EpubFontResolver.bodyAttributes("<BODY  class='a b'  epub:type='bodymatter'>")
        assertNotNull(attributes)
        assertEquals("a b", attributes!!["class"])
        assertEquals("bodymatter", attributes["epub:type"])
    }
}
