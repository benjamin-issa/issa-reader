package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubStyleSheet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What a book's own stylesheet asks for, once the renderer reads one. Ported
 * from `RenderTests.swift`'s `StyledChapterTests`.
 *
 * The bug these were written for: a reader reported that italics never
 * appeared, and every italic passage in the book was a `<p class="…">` against
 * a `font-style: italic` rule — which the renderer did not read. So was the
 * first-line indent, and so was the justification.
 *
 * Where the Swift suite reads a resolved `UIFont`'s traits, this reads the run
 * the font is chosen from: Android applies fonts later, in `:render-android`,
 * and `BundledFaceTest` there holds the faces to their traits.
 */
class StyledChapterTest {
    /** The parser with one sheet linked, as a chapter would link it. */
    private fun parseStyled(
        body: String,
        css: String,
        style: ReaderStyle = ReaderStyle(),
        columnWidth: Double = 320.0,
    ): StyledChapter {
        val sheet = EpubStyleSheet().adding(css)
        return parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><link rel="stylesheet" type="text/css" href="style.css"/></head>
            $body
            </html>
            """.trimIndent(),
            style = style, columnWidth = columnWidth,
            loadStyleSheet = { if (it == "style.css") sheet else null },
        )
    }

    /** The point size the run is set at. */
    private fun pointSize(result: StyledChapter, index: Int, style: ReaderStyle = ReaderStyle()): Double =
        style.fontSize * result.style(index).sizeScale

    @Test
    fun `a class that asks for italic is set in italic`() {
        // The reported bug exactly: no <em> anywhere, and the whole paragraph
        // is meant to be italic.
        val result = parseStyled("<body><p class=\"quiet\">Oh, me?</p></body>", ".quiet {font-style: italic}")
        assertTrue(result.style(0).italic)
    }

    @Test
    fun `a paragraph with no rule of its own is left upright`() {
        val result = parseStyled(
            "<body><p class=\"quiet\">Quiet.</p><p>Plain.</p></body>", ".quiet {font-style: italic}",
        )
        assertFalse(result.style(result.text.indexOf("Plain.")).italic)
    }

    @Test
    fun `emphasis inside a styled paragraph is still emphasis`() {
        val result = parseStyled("<body><p class=\"lead\">A <em>word</em>.</p></body>", ".lead {font-weight: bold}")
        val face = result.style(result.text.indexOf("word"))
        assertTrue(face.italic)
        // Still bold: the class is the paragraph's, and it reaches the <em>
        // through the same inheritance a browser would give it.
        assertTrue(face.bold)
    }

    @Test
    fun `the body's indent reaches a paragraph that never mentions one`() {
        // How a real book indents: one rule on <body>'s class, inherited.
        val result = parseStyled(
            "<body class=\"text\"><p>First.</p><p class=\"flush\">Second.</p></body>",
            ".text {text-indent: 5%} .flush {text-indent: 0}",
            columnWidth = 400.0,
        )
        assertEquals(20.0, result.style(0).paragraph.firstLineHeadIndent, 0.0)
        assertEquals(0.0, result.style(result.text.indexOf("Second.")).paragraph.firstLineHeadIndent, 0.0)
    }

    @Test
    fun `an indent is measured from the column, not from a quotation's margin`() {
        val result = parseStyled(
            "<body class=\"text\"><blockquote><p>Quoted.</p></blockquote></body>",
            ".text {text-indent: 5%}", columnWidth = 400.0,
        )
        val paragraph = result.style(0).paragraph
        // The quotation's own indent still applies to every line; the book's
        // first-line indent is added to it rather than replacing it.
        assertTrue(paragraph.headIndent > 0)
        assertEquals(paragraph.headIndent + 20, paragraph.firstLineHeadIndent, 0.0)
    }

    @Test
    fun `the reader can overrule the book's justification, but not its centring`() {
        val body = "<body class=\"text\"><p>Running text.</p><p class=\"epigraph\">An epigraph.</p></body>"
        val css = ".text {text-align: justify} .epigraph {text-align: center}"
        for ((setting, expected) in listOf(
            ReaderStyle.Justification.FOLLOW_BOOK to TextAlignment.JUSTIFIED,
            ReaderStyle.Justification.NEVER to TextAlignment.NATURAL,
            ReaderStyle.Justification.ALWAYS to TextAlignment.JUSTIFIED,
        )) {
            val result = parseStyled(body, css, style = ReaderStyle(justification = setting))
            assertEquals("$setting", expected, result.style(0).paragraph.alignment)
            // Centring is structure, not taste: it survives every setting.
            val centred = result.text.indexOf("An epigraph.")
            assertEquals(TextAlignment.CENTER, result.style(centred).paragraph.alignment)
        }
    }

    /**
     * `NEVER` used to answer "nothing" for a justified paragraph, which means
     * "nothing to say" — so the paragraph inherited a centred parent's
     * alignment and a body paragraph on a title page was centred line by line.
     */
    @Test
    fun `under Never, justification nested in a centred element is natural`() {
        for (outer in listOf("center", "right")) {
            val result = parseStyled(
                "<body><div class=\"c\"><p class=\"j\">Body text.</p></div></body>",
                ".c {text-align: $outer} .j {text-align: justify}",
                style = ReaderStyle(justification = ReaderStyle.Justification.NEVER),
            )
            assertEquals(outer, TextAlignment.NATURAL, result.style(0).paragraph.alignment)
        }
    }

    /**
     * Inline `style=` used to be read only when the chapter's sheet had at
     * least one rule, so the same markup rendered styled in one book and plain
     * in another. Both shapes the reader hands the parser: no loader at all,
     * and a loader whose sheets have nothing in them (`@page` only, margins
     * only — what a word-processor export links).
     */
    @Test
    fun `an inline style is honoured when the book has no stylesheet rules`() {
        for (withEmptySheet in listOf(false, true)) {
            val head = if (withEmptySheet) "<head><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head>" else ""
            val result = parse(
                "<html xmlns=\"http://www.w3.org/1999/xhtml\">$head<body>\n" +
                    "<p style=\"text-align:center\">Centred.</p><p>Plain <span style=\"font-style:italic\">slanted</span> text.</p>\n" +
                    "</body></html>",
                loadStyleSheet = if (withEmptySheet) ({ _: String -> EpubStyleSheet() }) else null,
            )
            assertEquals(TextAlignment.CENTER, result.style(0).paragraph.alignment)
            assertTrue(result.style(result.text.indexOf("slanted")).italic)
            assertFalse(result.style(result.text.indexOf("Plain")).italic)
        }
    }

    @Test
    fun `a book's font-size sizes the type without making a heading of it`() {
        val plain = parseStyled("<body><p>Plain.</p></body>", "")
        val larger = parseStyled("<body><p class=\"big\">Plain.</p></body>", ".big {font-size: 1.3em}")
        assertEquals(pointSize(plain, 0) * 1.3, pointSize(larger, 0), 0.0)
        // The leading and the gap beneath belong to headings, and this is not
        // one — the test that used to decide it was `sizeScale > 1.2`.
        assertEquals(plain.style(0).paragraph.lineHeightMultiple, larger.style(0).paragraph.lineHeightMultiple, 0.0)
        assertEquals(plain.style(0).paragraph.paragraphSpacing, larger.style(0).paragraph.paragraphSpacing, 0.0)
    }

    /**
     * Nesting compounds, so a book can reach an enormous size without ever
     * declaring one — and a line taller than the page cannot be paged through.
     */
    @Test
    fun `a book cannot set its text larger than the page can carry`() {
        val plain = parseStyled("<body><p>Plain.</p></body>", "")
        val nested = parseStyled(
            "<body class=\"big\"><div class=\"big\"><p class=\"big\">Plain.</p></div></body>", ".big {font-size: 2em}",
        )
        assertEquals(pointSize(plain, 0) * ChapterParser.MAXIMUM_FONT_SCALE, pointSize(nested, 0), 0.0)
    }

    @Test
    fun `a chapter with no stylesheet renders as it always did`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p class=\"quiet\">Oh, me?</p>\n</body></html>",
        )
        assertEquals("Oh, me?", result.text)
        assertFalse(result.style(0).italic)
    }

    /**
     * The rendered *string* must not depend on styling: every Ask passage
     * offset, every spoiler boundary and every saved highlight is measured in
     * it, and the indexer parses without a stylesheet while the page parses
     * with one. `IndexOffsetTest` holds the other end of this.
     */
    @Test
    fun `a stylesheet changes how a chapter looks and never what it says`() {
        val body = "<body class=\"text\"><h1>One</h1><p class=\"quiet\">Oh, me?</p>\n<p>Plain <em>enough</em>.</p></body>"
        val css = ".text {text-align: justify; text-indent: 5%}\n.quiet {font-style: italic}\nh1 {font-size: 1.1em}"
        assertEquals(parseStyled(body, "").text, parseStyled(body, css).text)
    }

    /** The heading flags and the leading and spacing they set, as `attributes(for:)` sets them. */
    @Test
    fun `a heading is set tighter, with more room beneath`() {
        val result = parse("<html><body><h2>Title</h2><p>Body.</p></body></html>")
        val heading = result.style(0)
        assertTrue(heading.isHeading && heading.bold)
        assertEquals(1.6, heading.sizeScale, 0.0)
        assertEquals(1.20 * 0.82, heading.paragraph.lineHeightMultiple, 1e-12)
        assertEquals(18 * 0.55, heading.paragraph.paragraphSpacing, 1e-12)
        val body = result.style(result.text.indexOf("Body."))
        assertEquals(1.20, body.paragraph.lineHeightMultiple, 0.0)
        assertEquals(18 * 0.30, body.paragraph.paragraphSpacing, 1e-12)
    }

    /** Hyphenation follows justification, and nothing else. */
    @Test
    fun `a justified paragraph hyphenates and a ragged one does not`() {
        val justified = parse("<html><body><p>Text.</p></body></html>", style = ReaderStyle(justification = ReaderStyle.Justification.ALWAYS))
        assertEquals(TextAlignment.JUSTIFIED, justified.style(0).paragraph.alignment)
        assertEquals(1.0, justified.style(0).paragraph.hyphenationFactor, 0.0)
        val ragged = parse("<html><body><p>Text.</p></body></html>")
        assertEquals(TextAlignment.NATURAL, ragged.style(0).paragraph.alignment)
        assertEquals(0.0, ragged.style(0).paragraph.hyphenationFactor, 0.0)
    }
}

/** The whitespace between two blocks, which is not content. Ported from `BlockWhitespaceTests`. */
class BlockWhitespaceTest {
    private fun text(html: String): String = parse(html).text

    /** The shipped bug, visible in the reader as a stray space before every paragraph but the first. */
    @Test
    fun `a newline between two paragraphs is not a space`() {
        val text = text(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p>First.</p>\n<p>Second.</p>\n</body></html>",
        )
        assertEquals("First.\nSecond.", text)
    }

    @Test
    fun `nor is a newline inside the paragraph's own opening`() {
        // The other half: source that wraps the opening tag onto its own line.
        val text = text(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p>\n  First.\n</p>\n<p>\n  Second.\n</p>\n</body></html>",
        )
        assertEquals("First. \nSecond.", text)
    }

    @Test
    fun `a space between two inline elements is content and stays`() {
        val text = text(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n" +
                "<p><span>One</span> <span>two</span> <em>three</em></p>\n</body></html>",
        )
        assertEquals("One two three", text)
    }

    @Test
    fun `a preformatted block keeps every space it was given`() {
        // A paragraph first, because the whole chapter's leading whitespace is
        // trimmed at the end of the parse — which would eat the indentation
        // this is about if the <pre> opened the document.
        val text = text(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p>Before.</p>\n" +
                "<pre>  indented\n  again</pre>\n</body></html>",
        )
        assertTrue("  indented\n  again" in text)
    }

    @Test
    fun `no paragraph in a real chapter opens with a space`() {
        val book = renderFixture("alice")
        for (item in book.spine.take(6)) {
            val data = try {
                book.archive.read(item.href)
            } catch (_: Exception) {
                continue
            }
            // Alice sets her shaped verse — the Mouse's Tale, the address on
            // the parcel of boots — in <pre>, whose indentation is the point
            // of it and is preserved on purpose.
            if ("<pre" in String(data, Charsets.UTF_8)) continue
            val text = ChapterParser(ReaderStyle()).parse(data, item.href).text
            assertFalse("${item.href} opens a line with a space", "\n " in text)
        }
    }

    /** Never more than one blank line, however deeply the blocks nest. */
    @Test
    fun `nested blocks close with at most one blank line`() {
        val text = text("<html><body><div><section><p>One.</p></section></div><p>Two.</p></body></html>")
        assertEquals("One.\n\nTwo.", text)
    }

    /** A `<br/>` is a line break with the enclosing element's attributes, and is never collapsed. */
    @Test
    fun `a line break survives and starts a fresh line`() {
        val text = text("<html><body><p>One<br/>   two</p></body></html>")
        assertEquals("One\ntwo", text)
    }
}
