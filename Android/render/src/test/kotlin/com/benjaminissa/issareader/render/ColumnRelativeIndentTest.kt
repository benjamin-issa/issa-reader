package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubStyleSheet
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/** A chapter parsed the way the reader parses one: a linked sheet, and a column width a percentage resolves against. */
private fun parseChapter(
    body: String,
    css: String,
    columnWidth: Double,
    loadImage: ((String) -> ChapterArtwork?)? = null,
): StyledChapter {
    val sheet = EpubStyleSheet().adding(css)
    return parse(
        """
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><link rel="stylesheet" type="text/css" href="style.css"/></head>
        $body
        </html>
        """.trimIndent(),
        maxImageWidth = columnWidth, columnWidth = columnWidth, loadImage = loadImage,
        loadStyleSheet = { if (it == "style.css") sheet else null },
    )
}

/**
 * A book cannot indent a first line off the page. Ported from
 * `ColumnRelativeIndentTests.swift`'s `IndentBoundTests`.
 *
 * An indent the width of the column pushes the paragraph's whole first line
 * into a zero-width fragment at the right edge, where it is clipped: the first
 * line of every such paragraph was invisible.
 */
class IndentBoundTest {
    @Test
    fun `an over-wide or infinite indent is held to half the column`() {
        for ((indent, expected) in listOf(
            // Parses to +infinity, which is not a length: ignored, as NaN is.
            "1e400em" to 0.0,
            "100%" to 160.0,
            // 450pt at the default 18pt: a large indent is still an indent.
            "25em" to 160.0,
        )) {
            val result = parseChapter(
                "<body><p class=\"wide\">A first line that should be seen.</p></body>",
                ".wide {text-indent: $indent}", columnWidth = 320.0,
            )
            val first = result.style(0).paragraph.firstLineHeadIndent
            assertTrue(first.isFinite())
            assertTrue("$indent gave $first", first <= 160)
            assertEquals("$indent gave $first", expected, first, 0.0)
        }
    }

    @Test
    fun `the bound is past any quotation's own indent, not instead of it`() {
        val result = parseChapter(
            "<body class=\"wide\"><blockquote><p>Quoted.</p></blockquote></body>",
            ".wide {text-indent: 100%}", columnWidth = 320.0,
        )
        val paragraph = result.style(0).paragraph
        assertTrue(paragraph.headIndent > 0)
        assertEquals(paragraph.headIndent + 160, paragraph.firstLineHeadIndent, 0.0)
    }

    @Test
    fun `an ordinary indent is untouched`() {
        val result = parseChapter("<body><p class=\"i\">Text.</p></body>", ".i {text-indent: 1.5em}", columnWidth = 320.0)
        assertEquals(27.0, result.style(0).paragraph.firstLineHeadIndent, 0.0)
    }
}

/**
 * A percentage indent follows the column. Ported from
 * `ColumnRelativeIndentTests.swift`: the attribute half, which on Android is
 * [StyledChapter.reindented]; that the laid-out first line really moves is
 * `:render-android`'s `ColumnRelativeIndentLayoutTest`.
 *
 * A percentage indent is a fraction of the column, and the column changes on
 * rotation, a split-screen drag or a window resize — none of which parses the
 * chapter again.
 */
class ColumnRelativeIndentTest {
    @Test
    fun `a 5 percent indent parsed at 300pt and laid out at 600pt is 30pt`() {
        val parsed = parseChapter(
            "<body class=\"text\"><p>First paragraph.</p><p>Second paragraph.</p></body>",
            ".text {text-indent: 5%}", columnWidth = 300.0,
        )
        assertEquals(15.0, parsed.style(0).paragraph.firstLineHeadIndent, 0.0)

        val wide = parsed.reindented(600.0)
        assertEquals(30.0, wide.style(0).paragraph.firstLineHeadIndent, 0.0)
        assertEquals(30.0, wide.style(wide.text.indexOf("Second")).paragraph.firstLineHeadIndent, 0.0)

        // And back again.
        val narrow = wide.reindented(300.0)
        assertEquals(15.0, narrow.style(0).paragraph.firstLineHeadIndent, 0.0)
        // Only attributes moved: every offset a highlight or a position is
        // measured in is the one the parser produced.
        assertEquals(parsed.text, narrow.text)
        assertEquals(parsed.fragmentRanges, narrow.fragmentRanges)
    }

    @Test
    fun `an em indent clamped to a wide column is clamped again for a narrow one`() {
        // 25em at the default 18pt is 450pt: allowed on a 1000pt column, but on
        // a 320pt one it would hide the first line.
        val parsed = parseChapter(
            "<body><p class=\"wide\">A paragraph.</p></body>", ".wide {text-indent: 25em}", columnWidth = 1000.0,
        )
        assertEquals(450.0, parsed.style(0).paragraph.firstLineHeadIndent, 0.0)
        val narrow = parsed.reindented(320.0)
        assertEquals(160.0, narrow.style(0).paragraph.firstLineHeadIndent, 0.0)
        assertEquals(450.0, narrow.reindented(1000.0).style(0).paragraph.firstLineHeadIndent, 0.0)
    }

    @Test
    fun `a plate and an unindented paragraph are left alone`() {
        val parsed = parseChapter(
            "<body class=\"text\"><p class=\"flush\">Flush.</p><p><img src=\"i.png\"/></p></body>",
            ".text {text-indent: 5%} .flush {text-indent: 0}", columnWidth = 300.0,
            loadImage = { SizedArtwork(40.0, 40.0) },
        )
        val wide = parsed.reindented(600.0)
        assertEquals(0.0, wide.style(0).paragraph.firstLineHeadIndent, 0.0)
        val image = wide.text.indexOf('\uFFFC')
        assertTrue(image >= 0)
        assertEquals(0.0, wide.style(image).paragraph.firstLineHeadIndent, 0.0)
    }

    /** Nothing to move at the parsed width: the same chapter back, as the Swift side leaves the storage alone. */
    @Test
    fun `reindenting at the parsed width changes nothing`() {
        val parsed = parseChapter("<body class=\"text\"><p>Text.</p></body>", ".text {text-indent: 5%}", columnWidth = 300.0)
        assertSame(parsed, parsed.reindented(300.0))
    }
}
