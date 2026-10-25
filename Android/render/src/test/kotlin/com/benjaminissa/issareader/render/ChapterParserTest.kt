package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubError
import com.benjaminissa.issareader.epub.EpubXml
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The parser half of `RenderTests.swift`'s `HTMLContentParserTests`: the
 * characters a chapter renders to. The layout half is in `:render-android`.
 */
class ChapterParserTest {
    @Test
    fun `keeps text that follows an inline element`() {
        val result = parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p>Hello <b>world</b> again</p>
            </body></html>
            """.trimIndent(),
        )
        // Losing the tail text after an inline element is the classic mixed
        // content bug; it silently mangles ordinary prose.
        assertTrue("Hello world again" in result.text)
    }

    @Test
    fun `records a character range for every element id`() {
        val result = parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p><span id="ch01-s0">First sentence. </span><span id="ch01-s1">Second sentence.</span></p>
            </body></html>
            """.trimIndent(),
        )
        val first = result.fragmentRanges.getValue("ch01-s0")
        val second = result.fragmentRanges.getValue("ch01-s1")
        assertTrue("First sentence" in result.text.substring(first.location, first.end))
        assertTrue("Second sentence" in result.text.substring(second.location, second.end))
        // Ranges must not overlap, or a highlight would cover both sentences.
        assertTrue(first.end <= second.location)
    }

    @Test
    fun `substitutes HTML named entities XML does not define`() {
        // &nbsp; is fatal to a strict XML parser unless rewritten; plenty of
        // real books use it, and without this they simply fail to open.
        val result = parse(
            """<html xmlns="http://www.w3.org/1999/xhtml"><body><p>a&nbsp;b&mdash;c&hellip;</p></body></html>""",
        )
        assertTrue("\u00A0" in result.text)
        assertTrue("—" in result.text)
        assertTrue("…" in result.text)
    }

    @Test
    fun `collapses source whitespace the way HTML does`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p>one     two\n     three</p>\n</body></html>",
        )
        assertTrue("one two three" in result.text)
    }

    /**
     * Publishers put verse and code directly in `<pre>` — Gutenberg marks up
     * poetry this way. The collapse guard used to read the *incoming* context
     * rather than the element's own, so a bare `<pre>`'s text lost every line
     * break while the nested `<pre><code>` form kept them.
     */
    @Test
    fun `a bare pre keeps its line breaks and indentation`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><pre>line one\n  line two\nline three</pre></body></html>",
        )
        assertTrue("line one\n  line two\nline three" in result.text)
    }

    @Test
    fun `text following an inline element inside pre stays preformatted`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><pre>one <i>two</i>\n  three</pre></body></html>",
        )
        assertTrue("two\n  three" in result.text)
    }

    @Test
    fun `flags structure the native renderer cannot represent`() {
        val simple = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Just prose.</p></body></html>")
        assertFalse(simple.complexity.requiresWebView)

        val complex = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><table><tr><td>a</td></tr></table></body></html>",
        )
        assertTrue(complex.complexity.hasTables)
        assertTrue(complex.complexity.requiresWebView)
    }

    /** The early return for `<script>` once left the flag unreachable. */
    @Test
    fun `a script is counted, and its text is not rendered`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Prose.</p><script>var x = 1;</script></body></html>",
        )
        assertTrue(result.complexity.hasScripting)
        assertEquals("Prose.", result.text)
    }

    /** A cover's `<svg>` wrapping a raster is not vector art; a drawing is. */
    @Test
    fun `an svg wrapping a bitmap is not vector art, and a drawing is`() {
        val cover = parse(
            """<html xmlns="http://www.w3.org/1999/xhtml"><body><svg xmlns="http://www.w3.org/2000/svg">""" +
                """<image href="c.jpg"/></svg></body></html>""",
        )
        assertFalse(cover.complexity.hasVectorArt)
        assertEquals(1, cover.complexity.imageCount)
        val drawing = parse(
            """<html xmlns="http://www.w3.org/1999/xhtml"><body><svg xmlns="http://www.w3.org/2000/svg">""" +
                """<g><path d="M0 0"/></g></svg></body></html>""",
        )
        assertTrue(drawing.complexity.hasVectorArt)
    }

    @Test
    fun `parses a real chapter out of a real book`() {
        // A spine item with real prose rather than the cover or nav page.
        val result = firstChapterLongerThan(renderFixture("alice"), 1000)
        assertTrue(result.text.length > 1000)
        assertFalse("<" in result.text)
    }

    /** The runs are the attributed string's: ordered, contiguous, and over every character. */
    @Test
    fun `the runs cover the text exactly`() {
        val result = firstChapterLongerThan(renderFixture("alice"), 1000)
        var expected = 0
        for (run in result.runs) {
            assertEquals(expected, run.start)
            assertTrue(run.end > run.start)
            expected = run.end
        }
        assertEquals(result.text.length, expected)
    }
}

/**
 * Regression tests for fragment-id nesting.
 *
 * Media overlays reference the innermost sentence span, but real EPUB markup
 * wraps those spans in sections, divs and paragraphs that also carry ids.
 */
class FragmentNestingTest {
    @Test
    fun `an outer element's id does not overwrite the sentence spans inside it`() {
        val result = parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <section id="pg-header">
              <p id="para1"><span id="pg-header-s0">First. </span><span id="pg-header-s1">Second.</span></p>
            </section>
            </body></html>
            """.trimIndent(),
        )
        // Every character of "First." must be attributed to the innermost
        // span, not to the section or paragraph that wraps it. Getting this
        // wrong highlights an entire chapter instead of one sentence.
        val first = result.fragmentRanges.getValue("pg-header-s0")
        assertEquals("pg-header-s0", result.fragmentIdAt(first.location))
        val second = result.fragmentRanges.getValue("pg-header-s1")
        assertEquals("pg-header-s1", result.fragmentIdAt(second.location))
    }

    /**
     * The image case returned before the id bookkeeping, so a contents entry
     * or an overlay addressed to `<img id>` resolved to nothing.
     */
    @Test
    fun `an id on an image itself is a place in the chapter`() {
        val plate = SizedArtwork(40.0, 40.0)
        val result = parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <p>Before.</p><img id="plate-3" src="p.png" alt="A plate"/><p>After.</p>
            </body></html>
            """.trimIndent(),
            loadImage = { plate },
        )
        val range = result.fragmentRanges.getValue("plate-3")
        val slice = result.text.substring(range.location, range.end)
        assertTrue(slice.startsWith("\uFFFC"))
        assertEquals("plate-3", result.fragmentIdAt(range.location))
        // And nothing else moved: the paragraphs either side are as they were.
        assertFalse("Before" in slice)
        assertFalse("After" in slice)
    }

    @Test
    fun `an outer id still covers text no inner span claims`() {
        val result = parse(
            """
            <html xmlns="http://www.w3.org/1999/xhtml"><body>
            <section id="outer">Loose text. <span id="inner-s0">Claimed.</span></section>
            </body></html>
            """.trimIndent(),
        )
        val outer = result.fragmentRanges.getValue("outer")
        assertEquals("outer", result.fragmentIdAt(outer.location))
        // The chapter must not open on stray whitespace from the source markup.
        assertTrue(result.text.startsWith("Loose text."))
        val inner = result.fragmentRanges.getValue("inner-s0")
        assertEquals("inner-s0", result.fragmentIdAt(inner.location))
    }

    /**
     * Trimming the chapter's ends moves every range with it. A range that
     * began inside the trimmed lead-in is dropped, as the Swift parser drops
     * it, rather than pointing before the text.
     */
    @Test
    fun `ranges move with the trimmed opening, and one that began inside it is dropped`() {
        val result = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><div id=\"wrap\"><br/>" +
                "<p id=\"p1\">One.</p></div></body></html>",
        )
        assertEquals("One.", result.text)
        assertEquals(TextRange(0, 4), result.fragmentRanges["p1"])
        assertFalse("wrap" in result.fragmentRanges)
    }
}

/** A chapter using ordinary named entities opens. */
class NamedEntityTest {
    private fun text(body: String): String =
        // The HTML5 short DOCTYPE, which is what an EPUB 3 chapter carries and
        // which declares no entities at all.
        parse("<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>$body</p></body></html>").text

    /** The hazard: without substitution the parse fails outright, and the chapter does not open. */
    @Test
    fun `an unsubstituted entity really does fail the parse`() {
        val raw = "<!DOCTYPE html>\n<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Stra&szlig;e</p></body></html>"
        try {
            EpubXml.parse(raw.toByteArray())
            fail("undefined entity — this is why the table exists")
        } catch (_: EpubError) {
        }
    }

    /**
     * An accented capital opening a sentence was enough to lose the chapter,
     * because the table held only lowercase forms and the substitution is
     * case-sensitive.
     */
    @Test
    fun `French and German prose survives`() {
        for ((input, expected) in listOf(
            "&Eacute;t&eacute;" to "Été",
            "Stra&szlig;e" to "Straße",
            "&Agrave; propos" to "À propos",
            "c&oelig;ur" to "cœur",
            "&Ccedil;a" to "Ça",
        )) {
            assertEquals(input, expected, text(input))
        }
    }

    @Test
    fun `symbols and Greek that appear in footnotes`() {
        for ((input, expected) in listOf(
            "3 &times; 4" to "3 × 4",
            "10 &divide; 2" to "10 ÷ 2",
            "&alpha; and &Omega;" to "α and Ω",
            "a &ne; b" to "a ≠ b",
            "&larr; back" to "← back",
        )) {
            assertEquals(input, expected, text(input))
        }
    }

    /**
     * The forty-eight HTML 4.01 names the renderer's own table lacked. Any one
     * of them failed the parse under the HTML5 DOCTYPE, so the chapter would
     * not open and search and the Ask index skipped it.
     */
    @Test
    fun `the names the old table lacked`() {
        val names = listOf(
            "alefsym" to 8501, "and" to 8743, "ang" to 8736, "asymp" to 8776, "circ" to 710,
            "cong" to 8773, "crarr" to 8629, "dArr" to 8659, "empty" to 8709, "exist" to 8707,
            "forall" to 8704, "hArr" to 8660, "image" to 8465, "isin" to 8712, "lArr" to 8656,
            "lang" to 9001, "lceil" to 8968, "lfloor" to 8970, "nabla" to 8711, "ni" to 8715,
            "notin" to 8713, "nsub" to 8836, "oplus" to 8853, "or" to 8744, "otimes" to 8855,
            "part" to 8706, "perp" to 8869, "piv" to 982, "prod" to 8719, "prop" to 8733,
            "rArr" to 8658, "rang" to 9002, "rceil" to 8969, "real" to 8476, "rfloor" to 8971,
            "sdot" to 8901, "sim" to 8764, "sub" to 8834, "sube" to 8838, "sum" to 8721,
            "sup" to 8835, "supe" to 8839, "there4" to 8756, "thetasym" to 977, "tilde" to 732,
            "uArr" to 8657, "upsih" to 978, "weierp" to 8472,
        )
        for ((name, code) in names) {
            assertEquals(name, "a ${String(Character.toChars(code))} b", text("a &$name; b"))
        }
    }

    /** And all of HTML 4.01, in one chapter: the renderer reads `:epub`'s table. */
    @Test
    fun `every HTML 4_01 name opens`() {
        val table = EpubXml.htmlNamedEntities.entries.sortedBy { it.key }
        assertEquals(248, table.size)
        // One chapter, each name between bars, compared name by name in
        // scalars so a failure says which one. Split on the bar itself: a bar
        // followed by `&zwj;` is one grapheme, and would not split by cluster.
        val body = table.joinToString("|") { "&${it.key};" }
        val parts = text(body).split('|')
        assertEquals(table.size, parts.size)
        for ((entry, part) in table.zip(parts)) {
            // A lone space-like entity is collapsed to a space, as HTML would.
            val expected = ChapterParser.collapseWhitespace(String(Character.toChars(entry.value)))
            assertEquals("&${entry.key}; gave ${part.map { it.code.toString(16) }}", expected, part)
        }
    }

    @Test
    fun `the five XML predefined entities are left to the parser`() {
        assertEquals("a & b < c", text("a &amp; b &lt; c"))
    }
}

/** A plate taller than the page is scaled to fit it. */
class TallImageTest {
    private fun plate(text: StyledChapter): ChapterPlate {
        assertEquals(1, text.plates.size)
        return text.plates.single()
    }

    /** A full-page frontispiece: 800×3000, the shape Gutenberg and comics-style EPUBs ship. */
    private fun parsePlate(width: Double, height: Double): StyledChapter = parse(
        """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
        <p><img src="plate.jpg" alt="A plate"/></p></body></html>
        """.trimIndent(),
        maxImageWidth = width, maxImageHeight = height, loadImage = { SizedArtwork(800.0, 3000.0) },
    )

    /**
     * Scaled to the column only, an 800×3000 plate became 320×1200 on a
     * ~600pt page: pagination gave it a page whose content extent was twice
     * the canvas, the draw clipped, and the lower half was painted outside the
     * page and unreachable — the turn skipped straight past it.
     */
    @Test
    fun `it fits the page, not merely the column`() {
        val size = plate(parsePlate(320.0, 600.0))
        assertTrue("the whole plate has to be on one page", size.displayHeight <= 600 + 0.5)
        assertTrue(size.displayWidth <= 320 + 0.5)
        assertTrue("aspect preserved", kotlin.math.abs(size.displayWidth / size.displayHeight - 800.0 / 3000.0) < 0.001)
    }

    /** The width bound still governs when it is the tighter of the two. */
    @Test
    fun `a wide short image is still bounded by the column`() {
        val text = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p><img src=\"w.jpg\"/></p></body></html>",
            maxImageWidth = 320.0, maxImageHeight = 600.0, loadImage = { SizedArtwork(2000.0, 100.0) },
        )
        assertEquals(320.0, plate(text).displayWidth, 0.5)
    }

    /** Never up: an upscaled decoration looks worse than a small one. */
    @Test
    fun `a small decoration is left alone`() {
        val text = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p><img src=\"s.jpg\"/></p></body></html>",
            maxImageWidth = 320.0, maxImageHeight = 600.0, loadImage = { SizedArtwork(60.0, 60.0) },
        )
        assertEquals(60.0, plate(text).displayWidth, 0.0)
        assertEquals(60.0, plate(text).displayHeight, 0.0)
    }

    /**
     * A plate's two characters carry its own paragraph: centred, unindented,
     * a reading size of air above and below, its alt text, and no indent
     * request for a resize to re-apply.
     */
    @Test
    fun `a plate is its own centred paragraph, carrying its alt text`() {
        val text = parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><blockquote><p>Q.</p>" +
                "<img src=\"p.png\" alt=\"  A map \"/></blockquote><p>After.</p></body></html>",
            loadImage = { SizedArtwork(100.0, 50.0) },
        )
        val offset = text.text.indexOf('\uFFFC')
        assertEquals('\n', text.text[offset + 1])
        for (index in listOf(offset, offset + 1)) {
            val style = text.style(index)
            assertEquals(TextAlignment.CENTER, style.paragraph.alignment)
            assertEquals(0.0, style.paragraph.headIndent, 0.0)
            assertEquals(0.0, style.paragraph.firstLineHeadIndent, 0.0)
            assertEquals(18.0, style.paragraph.paragraphSpacing, 0.0)
            assertEquals(18.0, style.paragraph.paragraphSpacingBefore, 0.0)
            assertEquals("A map", style.imageAlt)
            assertEquals("p.png", style.imageHref)
        }
        assertEquals(0, text.runAt(offset)?.plateIndex)
        assertEquals(offset, text.plates.single().offset)
    }

    /** An image that the loader cannot size takes no place at all — neither character. */
    @Test
    fun `an image with no size is not in the text`() {
        for (artwork in listOf(null, SizedArtwork(0.0, 10.0), SizedArtwork(Double.NaN, 10.0))) {
            val text = parse(
                "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>A<img src=\"p.png\"/>B</p></body></html>",
                loadImage = { artwork },
            )
            assertEquals("AB", text.text)
            assertEquals(1, text.complexity.imageCount)
        }
    }

    /** The src resolves against the chapter's own path, percent-escapes and all. */
    @Test
    fun `an image src resolves against the chapter`() {
        val asked = ArrayList<String>()
        parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p><img src=\"../images/a%20b.png\"/></p></body></html>",
            baseHref = "OEBPS/text/c.xhtml",
            loadImage = { asked.add(it); null },
        )
        assertEquals(listOf("OEBPS/images/a b.png"), asked)
        assertNotNull(asked.single())
    }
}
