package com.benjaminissa.issareader.render.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.RenderedPage
import com.benjaminissa.issareader.render.StyledChapter
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.ceil

/**
 * E-Ink mode's marks, rasterised: what they are is which pixels are black,
 * which no accessibility query or path comparison can see.
 *
 * The chapter is three sentences, the middle one marked and wrapped over
 * several lines, so that a mark that only reached the first line, or ran on
 * into the sentences either side, fails here.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class EInkMarksTest {
    private val sentences = listOf(
        "The sentence before the mark runs over the first line of this column and on to the next. ",
        "The marked sentence is long enough to wrap over several lines of the page, so that the block around it has " +
            "a first line, some middle lines and a last line of its own, which is the shape that matters here. ",
        "And a sentence after it to close the page.",
    )
    private val chapter = handBuiltSentences(sentences) { "s$it" }
    private val style = ReaderStyle(theme = ReaderTheme.EINK)
    private val ink = ReaderTheme.EINK.text
    private val width = 340
    private val height = 560

    private fun marked(layout: ChapterLayout): List<List<PageRect>> =
        layout.highlightLines("s1", layout.pages.first())

    private fun laid(pageHeight: Double = height.toDouble(), pageStyle: ReaderStyle = style) =
        laidOut(chapter, width.toDouble(), pageHeight, pageStyle)

    private fun drawn(
        layout: ChapterLayout,
        treatment: PageDrawing.Treatment?,
        page: RenderedPage = layout.pages.first(),
        canvasHeight: Int = height,
    ): Bitmap {
        val bitmap = Bitmap.createBitmap(width, canvasHeight, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        val marks = if (treatment == null) emptyList() else listOf(PageDrawing.Mark(marked(layout), ink, treatment))
        PageDrawing.draw(canvas, layout, page, marks)
        return bitmap
    }

    private fun Bitmap.black(x: Int, y: Int) = Color.red(getPixel(x, y)) < 64
    private fun Bitmap.white(x: Int, y: Int) = Color.red(getPixel(x, y)) > 192

    /** Black pixels in [rect], shrunk by [inset] to stay clear of a mark's edge. */
    private fun blackIn(bitmap: Bitmap, rect: PageRect, inset: Int = 0): Int {
        var count = 0
        for (y in (rect.minY.toInt() + inset) until (rect.maxY.toInt() - inset).coerceAtMost(bitmap.height)) {
            for (x in (rect.minX.toInt() + inset) until (rect.maxX.toInt() - inset)) {
                if (bitmap.black(x, y)) count++
            }
        }
        return count
    }

    private fun span(line: List<PageRect>) = line.minOf { it.minX }.toInt()..line.maxOf { it.maxX }.toInt()

    /** The row the rule sits on: inside the line's box. */
    private fun ruleRow(line: List<PageRect>, width: Int = 3) = ceil(line.maxOf { it.maxY }).toInt() - 1 - width / 2 - 1

    private fun assertRuled(bitmap: Bitmap, line: List<PageRect>, y: Int) {
        val (from, to) = span(line).let { it.first + 1 to it.last - 2 }
        for (x in from..to) assertTrue("no rule at ($x, $y)", bitmap.black(x, y))
    }

    @Test
    fun `underline runs under every line of a wrapped sentence and no other`() {
        val layout = laid()
        val lines = marked(layout)
        assertTrue("the sentence has to wrap for this to test anything", lines.size >= 3)
        val page = drawn(layout, PageDrawing.Treatment.UNDERLINE)
        for (line in lines) assertRuled(page, line, ruleRow(line))

        // The line before the sentence has no rule along its foot.
        val before = layout.highlightLines("s0", layout.pages.first()).first()
        val y = ruleRow(before)
        assertTrue("a rule ran on into the sentence before", span(before).any { !page.black(it.coerceAtMost(width - 1), y) })
    }

    @Test
    fun `underline stays out of the next line at tight spacing`() {
        val tight = style.copy(lineSpacing = ReaderStyle.LineSpacing.TIGHT)
        val layout = laidOut(chapter, width.toDouble(), height.toDouble(), tight)
        val lines = marked(layout)
        val page = drawn(layout, PageDrawing.Treatment.UNDERLINE)
        val plain = drawn(layout, null)
        for (line in lines) {
            val bottom = line.maxOf { it.maxY }.toInt()
            for (x in span(line)) {
                val y = (bottom + 1).coerceAtMost(height - 1)
                if (x < width) assertEquals("the rule reached the next line at ($x, $y)", plain.getPixel(x, y), page.getPixel(x, y))
            }
        }
    }

    /** The canvas ends where the page does here, as a page's last line does, so a rule below the box would not be drawn at all. */
    @Test
    fun `underline is there on the page's last line`() {
        val layout = laid()
        val lines = marked(layout)
        val foot = ceil(lines.last().maxOf { it.maxY }).toInt()
        val page = drawn(layout, PageDrawing.Treatment.UNDERLINE, canvasHeight = foot)
        assertRuled(page, lines.last(), ruleRow(lines.last()))
    }

    @Test
    fun `a stored highlight is a dashed line, not a solid one`() {
        val layout = laid()
        val line = marked(layout).first()
        val page = drawn(layout, PageDrawing.Treatment.DASHED_UNDERLINE)
        val y = ruleRow(line, width = 2)
        val plain = drawn(layout, null)
        val row = span(line).filter { it < width }
        // Only the columns the words don't already fill, so the gaps are the dashes'.
        val clear = row.filter { !plain.black(it, y) }
        assertTrue("the fixture left no clear columns", clear.size > 20)
        assertTrue("no dashes", clear.any { page.black(it, y) })
        assertTrue("no gaps", clear.any { !page.black(it, y) })
    }

    @Test
    fun `outline has nothing inside it`() {
        val layout = laid()
        val lines = marked(layout)
        val page = drawn(layout, PageDrawing.Treatment.OUTLINE)
        val plain = drawn(layout, null)
        // The block's edge is new ink along the top of its first line, over a
        // run of pixels too long to be anything but a line.
        val first = lines.first()
        val top = first.minOf { it.minY }.toInt()
        val row = (top - 3..top + 2).maxOf { y -> span(first).filter { it < width }.count { page.black(it, y) && !plain.black(it, y) } }
        assertTrue("no edge along the block ($row pixels)", row > 100)
        // Inside a middle line the page is what it was: text, and no fill.
        for (rect in lines[1]) {
            assertEquals(blackIn(plain, rect, inset = 3), blackIn(page, rect, inset = 3))
        }
    }

    @Test
    fun `inverted is white words on a black block, and the rest of the page is untouched`() {
        val layout = laid()
        val lines = marked(layout)
        val page = drawn(layout, PageDrawing.Treatment.INVERTED)
        val plain = drawn(layout, null)
        val rect = lines[1].first()
        var words = 0
        var ground = 0
        // Clear of the block's rounded corners and its antialiased edge.
        for (y in rect.minY.toInt() + 6 until rect.maxY.toInt() - 6) {
            for (x in rect.minX.toInt() + 8 until rect.maxX.toInt() - 8) {
                // Solid pixels only: an antialiased edge is neither.
                if (plain.getPixel(x, y) == Color.BLACK) {
                    assertTrue("a word's pixel at ($x, $y) was not turned white", page.white(x, y))
                    words++
                } else if (plain.getPixel(x, y) == Color.WHITE) {
                    assertTrue("the ground at ($x, $y) was not turned black", page.black(x, y))
                    ground++
                }
            }
        }
        assertTrue("the line had no words on it", words > 100)
        assertTrue(ground > 100)

        val after = layout.highlightLines("s2", layout.pages.first()).last().first()
        assertEquals("the sentence after changed", blackIn(plain, after, inset = 2), blackIn(page, after, inset = 2))
    }

    /** The ink is the chapter's one paint, so a pass that left it white would draw the whole next page white. */
    @Test
    fun `inverted leaves the layout's ink as it found it`() {
        val layout = laid()
        val before = layout.ink
        drawn(layout, PageDrawing.Treatment.INVERTED)
        assertEquals(before, layout.ink)
        assertTrue(inkCoverage(layout, layout.pages.first()) > 0.01)
    }

    /** The picture goes over the block rather than under it, and the words' pass doesn't draw it again. */
    @Test
    fun `a picture in an inverted sentence is left alone`() {
        val source = plateChapter()
        val layout = laidOut(source, width.toDouble(), height.toDouble(), style)
        val page = layout.pages.first()
        val everything = layout.lines(com.benjaminissa.issareader.render.TextRange(0, layout.text.length), page)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        PageDrawing.draw(canvas, layout, page, listOf(PageDrawing.Mark(everything, ink, PageDrawing.Treatment.INVERTED)))
        val red = (0 until height step 2).flatMap { y -> (0 until width step 2).map { x -> bitmap.getPixel(x, y) } }
            .count { Color.red(it) > 200 && Color.green(it) < 80 }
        assertTrue("the picture was covered ($red pixels of it left)", red > 100)
    }

    /** A paragraph, a red picture, and a paragraph. */
    private fun plateChapter(): StyledChapter {
        val red = Bitmap.createBitmap(200, 120, Bitmap.Config.ARGB_8888).apply { eraseColor(Color.RED) }
        return parse(
            "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>Before it.</p>" +
                "<img src=\"plate.png\" alt=\"A plate\"/><p>After it.</p></body></html>",
            style = style,
            loadImage = { BitmapArtwork(red) },
        )
    }

    @Test
    fun `no mark is drawn for lines that are not on the page`() {
        val layout = laid()
        val plain = drawn(layout, null)
        for (treatment in PageDrawing.Treatment.entries) {
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            canvas.drawColor(Color.WHITE)
            PageDrawing.draw(canvas, layout, layout.pages.first(), listOf(PageDrawing.Mark(emptyList(), ink, treatment)))
            assertTrue("$treatment drew something", bitmap.sameAs(plain))
        }
    }

    @Test
    fun `off, a mark is still a fill under the text`() {
        val layout = laidOut(chapter, width.toDouble(), height.toDouble(), ReaderStyle())
        val tint = ReaderTheme.PAPER.highlight
        val mark = PageDrawing.Mark(marked(layout), tint)
        assertEquals(PageDrawing.Treatment.FILL, mark.treatment)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        PageDrawing.draw(canvas, layout, layout.pages.first(), listOf(mark))
        val rect = marked(layout)[1].first()
        assertNotEquals(Color.WHITE, bitmap.getPixel(rect.minX.toInt() + 2, rect.minY.toInt() + 1))
        assertFalse(bitmap.sameAs(drawn(layout, null)))
    }
}
