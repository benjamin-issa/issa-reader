package com.benjaminissa.issareader.render.android

import com.benjaminissa.issareader.epub.EpubStyleSheet
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.StyledChapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

/**
 * A percentage indent follows the column, in the laid-out glyphs and not only
 * in the attribute. Ported from `ColumnRelativeIndentTests.swift`; the
 * attribute half is `:render`'s `ColumnRelativeIndentTest`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class ColumnRelativeIndentLayoutTest {
    private fun parseChapter(body: String, css: String, columnWidth: Double): StyledChapter {
        val sheet = EpubStyleSheet().adding(css)
        val html = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><head><link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/></head>$body</html>"
        return ChapterParser(
            ReaderStyle(), maxImageWidth = columnWidth, columnWidth = columnWidth,
            loadStyleSheet = { if (it == "style.css") sheet else null },
        ).parse(html.toByteArray(), "c.xhtml")
    }

    @Test
    fun `a 5 percent indent parsed at 300pt and laid out at 600pt is 30pt, in the layout`() {
        val parsed = parseChapter(
            "<body class=\"text\"><p>First paragraph.</p><p>Second paragraph.</p></body>", ".text {text-indent: 5%}", 300.0,
        )
        val layout = ChapterLayout(parsed, ReaderStyle(), testFonts)
        layout.layout(600.0, 800.0)
        assertEquals(30.0, layout.chapter.runAt(0)!!.style.paragraph.firstLineHeadIndent, 0.0)
        layout.layout(300.0, 800.0)
        assertEquals(15.0, layout.chapter.runAt(0)!!.style.paragraph.firstLineHeadIndent, 0.0)
        assertEquals(parsed.text, layout.text)
    }

    @Test
    fun `the laid-out first line really moves, not only the attribute`() {
        val parsed = parseChapter("<body class=\"text\"><p id=\"p\">Indented paragraph text.</p></body>", ".text {text-indent: 10%}", 300.0)
        val layout = ChapterLayout(parsed, ReaderStyle(), testFonts)
        layout.layout(300.0, 800.0)
        val before = layout.highlightRects("p", layout.pages.first()).first()
        layout.layout(600.0, 800.0)
        val after = layout.highlightRects("p", layout.pages.first()).first()
        assertTrue("narrow column starts at ${before.minX}", abs(before.minX - 30) < 1)
        assertTrue("wide column starts at ${after.minX}", abs(after.minX - 60) < 1)
    }
}

/**
 * The faces a chapter is set in, run by run. Ported from
 * `FontParseCacheTests.swift`: on Android the faces are chosen when the spans
 * are built, so the cache under test is [SpanBuilder]'s, and every case is a
 * pair of requests that must not collide.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class FontParseCacheTest {
    /** Alternating, so a cache that returned the previous answer would be caught on the second plain run. */
    private val markup = """
        <html><body>
        <h1>A Heading</h1>
        <p>Plain. <em>Emphasis.</em> Plain again. <strong>Strong.</strong> Plain once more.</p>
        <h1>Another Heading</h1>
        <p>Closing plain text.</p>
        </body></html>
    """.trimIndent()

    private fun spans(style: ReaderStyle = ReaderStyle(typeface = ReaderStyle.Typeface.Bundled(ReaderStyle.DEFAULT_FAMILY), fontSize = 18.0)) =
        SpanBuilder(testFonts, style, scale = 1.0).build(parse(markup, style = style))

    private fun face(text: android.text.Spanned, word: String): FaceSpan {
        val at = text.indexOf(word)
        assertTrue("\"$word\" is not in the parsed text", at >= 0)
        return text.getSpans(at, at + 1, FaceSpan::class.java).single()
    }

    @Test
    fun `emphasis is set in italic and the text after it is not`() {
        val text = spans()
        assertTrue(face(text, "Emphasis").face.isItalic)
        assertTrue("the run after an emphasis kept the italic face", !face(text, "Plain again").face.isItalic)
        assertTrue(!face(text, "Plain.").face.isItalic)
    }

    @Test
    fun `strong is set in bold and the text after it is not`() {
        val text = spans()
        val strong = face(text, "Strong")
        val after = face(text, "Plain once more")
        assertNotEquals("${strong.face.member} was used for both the strong run and the plain one after it", strong.face.member, after.face.member)
        assertEquals("two plain runs either side of the markup must be set identically", face(text, "Plain.").face.member, after.face.member)
    }

    /** The heading scale multiplies the size, and the *second* heading is the one that proves the cache is keyed and not merely first-write-wins. */
    @Test
    fun `the heading scale is part of the key`() {
        val text = spans()
        val heading = face(text, "A Heading")
        val second = face(text, "Another Heading")
        val body = face(text, "Plain.")
        assertTrue(heading.sizePx > body.sizePx)
        assertEquals("the second heading came back at ${second.sizePx} rather than ${heading.sizePx}", heading.sizePx, second.sizePx, 0f)
    }

    /** One build's faces do not reach the next: two builders, two styles, two answers. */
    @Test
    fun `one parse's fonts do not reach the next`() {
        val a = spans(ReaderStyle(fontSize = 14.0))
        val b = spans(ReaderStyle(fontSize = 28.0))
        assertEquals(14f, face(a, "Plain.").sizePx, 0f)
        assertEquals(28f, face(b, "Plain.").sizePx, 0f)
    }

    /** `<strong><em>` keeps both: the bold italic, not bold upright. */
    @Test
    fun `strong emphasis is bold italic`() {
        val style = ReaderStyle()
        val text = SpanBuilder(testFonts, style, 1.0).build(parse("<html><body><p><strong><em>Both.</em></strong></p></body></html>"))
        val both = face(text, "Both.").face
        assertTrue(both.isBold && both.isItalic)
    }
}
