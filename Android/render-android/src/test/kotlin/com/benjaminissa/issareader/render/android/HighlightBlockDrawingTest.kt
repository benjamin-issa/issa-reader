package com.benjaminissa.issareader.render.android

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Region
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.render.HighlightBlock
import com.benjaminissa.issareader.render.LocatorAnchoring
import com.benjaminissa.issareader.render.PagePoint
import com.benjaminissa.issareader.render.PageRect
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.render.TextRange
import com.github.takahirom.roborazzi.captureRoboImage
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import kotlin.math.abs

/**
 * The highlight block as Android draws it. Ported from
 * `HighlightBlockTests.swift`: the two cases that rasterise, now against
 * `android.graphics.Path` — the path the page really fills — and the three
 * that lay out a real chapter. The geometry cases are `:render`'s
 * `HighlightBlockTest`.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class HighlightBlockDrawingTest {
    private val staircase = listOf(
        listOf(PageRect(120.0, 0.0, 200.0, 26.0)),
        listOf(PageRect(0.0, 26.0, 320.0, 26.0)),
        listOf(PageRect(0.0, 52.0, 90.0, 26.0)),
    )
    private val style = HighlightBlock.Style.forFontSize(18.0)

    /** A 340 × 80 canvas the size of a phone's page, y growing downwards, cleared to nothing. */
    private fun raster(draw: (Canvas) -> Unit): Bitmap {
        val bitmap = Bitmap.createBitmap(340, 80, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(Color.TRANSPARENT)
        draw(Canvas(bitmap))
        return bitmap
    }

    /** White at 0.22, which is what a light page's highlighter is. */
    private val fill = Paint().apply { color = Color.argb(56, 255, 255, 255); style = Paint.Style.FILL }

    private fun alpha(bitmap: Bitmap, x: Int, y: Int) = Color.alpha(bitmap.getPixel(x, y))

    /**
     * The regression test for the band. It rasterises, because the band is a
     * composite of two fills and no amount of rectangle comparison can see it.
     */
    @Test
    fun `the seam is exactly as dark as the middle of a line`() {
        val block = HighlightBlock.path(lines = staircase, style = style).toAndroidPath()
        val painted = raster { it.drawPath(block, fill) }
        // x = 200 sits well inside the first two rows, and y = 26 is their
        // seam; y = 12 and y = 39 are the middles of those rows.
        val seam = alpha(painted, 200, 26)
        val centre = alpha(painted, 200, 39)
        assertEquals("the seam painted $seam, the middle of a line $centre", centre, seam)
        assertTrue("0.22 of 255 is 56, and it was $centre", abs(centre - 56) <= 1)
        assertEquals(centre, alpha(painted, 200, 12))
        assertEquals("the lower seam too", centre, alpha(painted, 50, 52))

        // And the same picture drawn the old way, to show the test can fail:
        // one rounded rect per line, each grown by 1 pt vertically, so the two
        // pads share 2 pt at the seam and the colour is composited twice.
        val control = raster { canvas ->
            for (rect in staircase.flatten()) {
                canvas.drawRoundRect(
                    RectF((rect.minX - 2).toFloat(), (rect.minY - 1).toFloat(), (rect.maxX + 2).toFloat(), (rect.maxY + 1).toFloat()),
                    3f, 3f, fill,
                )
            }
        }
        val oldSeam = alpha(control, 200, 26)
        val oldCentre = alpha(control, 200, 39)
        assertTrue("the old drawing should darken the seam ($oldSeam vs $oldCentre)", oldSeam > oldCentre + 20)
        assertTrue(abs(oldCentre - 56) <= 1)
    }

    @Test
    fun `the whole block rasterises to one flat tone`() {
        val block = HighlightBlock.path(lines = staircase, style = style).toAndroidPath()
        val painted = raster { it.drawPath(block, fill) }
        // Every pixel a good way inside the shape, seams included, must carry
        // the same alpha; anything else is a second fill overlapping a first.
        var interior = 0
        for (row in HighlightBlock.rows(staircase, style.horizontal)) {
            var x = row.minX + 6
            while (x < row.maxX - 6) {
                var y = row.minY + 2
                while (y < row.maxY - 2) {
                    if (x >= 0 && y >= 0 && x < 340 && y < 80) {
                        assertEquals("uneven at $x, $y", 56, alpha(painted, x.toInt(), y.toInt()))
                        interior += 1
                    }
                    y += 1
                }
                x += 1
            }
        }
        assertTrue(interior > 5_000)
    }

    /**
     * The Android path covers what the block's own geometry says it covers:
     * the arcs drawn by `arcTo` are the arcs [HighlightBlock] worked out.
     */
    @Test
    fun `the Android path and the block's geometry agree`() {
        val shape = HighlightBlock.path(lines = staircase, style = style)
        val region = Region().apply { setPath(shape.toAndroidPath(), Region(-10, -10, 400, 100)) }
        var checked = 0
        for (x in -5..330 step 3) {
            for (y in -3..80 step 2) {
                val inside = PagePoint(x + 0.5, y + 0.5) in shape
                // Clear of the edge by a pixel either way, where a pixel's
                // rasterisation can honestly go either way.
                val clear = listOf(-1.0, 1.0).all { dx -> listOf(-1.0, 1.0).all { dy -> (PagePoint(x + 0.5 + dx, y + 0.5 + dy) in shape) == inside } }
                if (!clear) continue
                assertEquals("disagreed at $x, $y", inside, region.contains(x, y))
                checked += 1
            }
        }
        assertTrue(checked > 1000)
    }

    /** The same shape magnified, so the corners and the two steps can be looked at rather than only asserted about. */
    @Test
    fun `the block can be looked at`() {
        val block = HighlightBlock.path(lines = staircase, style = style).toAndroidPath()
        val bitmap = Bitmap.createBitmap(1000, 250, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        canvas.drawColor(Color.WHITE)
        canvas.scale(3f, 3f)
        canvas.translate(4f, 3f)
        canvas.drawPath(block, Paint(Paint.ANTI_ALIAS_FLAG).apply { color = ReaderTheme.PAPER.highlight.argb })
        bitmap.captureRoboImage("build/outputs/roborazzi/highlight-block.png")
    }

    // Against a real chapter

    @Test
    fun `every wrapped sentence of a real chapter makes one covering block`() {
        check(readalongChapter(), HighlightBlock.Style.forFontSize(18.0))
    }

    @Test
    fun `the same holds at every line spacing, and justified`() {
        for (style in listOf(
            ReaderStyle(lineSpacing = ReaderStyle.LineSpacing.TIGHT),
            ReaderStyle(lineSpacing = ReaderStyle.LineSpacing.NORMAL),
            ReaderStyle(lineSpacing = ReaderStyle.LineSpacing.ROOMY),
            ReaderStyle(lineSpacing = ReaderStyle.LineSpacing.NORMAL, justification = ReaderStyle.Justification.ALWAYS),
        )) {
            check(readalongChapter(style), HighlightBlock.Style.forFontSize(style.fontSize), style)
        }
    }

    /**
     * A wider net than the four narrated sentences the readalong fixture
     * holds: hundreds of real wrapped selections out of a real book, on a
     * justified page.
     */
    @Test
    fun `a long selection in a real book is one covering block too`() {
        val justified = ReaderStyle(justification = ReaderStyle.Justification.ALWAYS)
        val layout = laidOut(aliceChapterLongerThan(4000, justified), 300.0, 480.0, justified)
        val style = HighlightBlock.Style.forFontSize(18.0)
        var wrapped = 0
        for (page in layout.pages.take(6)) {
            var location = page.characterRange.location
            while (location < page.characterRange.end) {
                val range = TextRange(location, minOf(140, page.characterRange.end - location))
                location += 97
                val lines = layout.lines(range, page)
                val rows = HighlightBlock.rows(lines, style.horizontal)
                if (rows.size < 2) continue
                wrapped += 1
                val block = HighlightBlock.path(lines = lines, style = style)
                assertBounds(block.boundingBox!!, expectedBounds(lines, style), "selection at ${range.location}")
                for (row in rows) {
                    assertTrue("the middle of a row of the selection at ${range.location} is outside its own block", PagePoint(row.midX, row.midY) in block)
                }
            }
        }
        assertTrue("the sweep should have found plenty of wrapped selections (was $wrapped)", wrapped >= 25)
    }

    private fun expectedBounds(lines: List<List<PageRect>>, style: HighlightBlock.Style): PageRect {
        val rows = HighlightBlock.rows(lines, style.horizontal)
        val box = rows.drop(1).fold(rows.first()) { all, next -> all.union(next) }
        return box.copy(y = box.y - style.vertical, height = box.height + style.vertical * 2)
    }

    private fun assertBounds(actual: PageRect, expected: PageRect, what: String) {
        assertTrue("$what: $actual against $expected", abs(actual.minX - expected.minX) < 0.01 && abs(actual.minY - expected.minY) < 0.01)
        assertTrue("$what: $actual against $expected", abs(actual.maxX - expected.maxX) < 0.01 && abs(actual.maxY - expected.maxY) < 0.01)
    }

    /** Narrow, so most of the fixture's sentences wrap: an unwrapped sentence is one rectangle and tests nothing here. */
    private fun check(chapter: com.benjaminissa.issareader.render.StyledChapter, block: HighlightBlock.Style, style: ReaderStyle = ReaderStyle()) {
        val layout = laidOut(chapter, 240.0, 560.0, style)
        var wrapped = 0
        for (id in chapter.fragmentRanges.keys.sorted()) {
            val page = layout.pageContainingFragment(id) ?: continue
            val lines = layout.highlightLines(id, page)
            val rows = HighlightBlock.rows(lines, block.horizontal)
            if (rows.size < 2) continue
            wrapped += 1
            val shape = HighlightBlock.path(lines = lines, style = block)
            assertBounds(shape.boundingBox!!, expectedBounds(lines, block), "fragment $id")
            for (row in rows) assertTrue("the middle of a row of $id is outside its own highlight", PagePoint(row.midX, row.midY) in shape)
        }
        // Four narrated sentences is all the fixture holds; at this width every one of them wraps.
        assertTrue("the fixture should offer several wrapped sentences (was $wrapped)", wrapped >= 4)
    }
}

/**
 * A saved page anchors on a fragment that begins on it. Ported from
 * `LocatorAnchoringTests.swift`'s `savedPageAnchorsOnItsOwnFragment`, the case
 * that needs a laid-out chapter.
 *
 * The same drift from the writing side: the fragment a page anchors on must
 * begin on that page. The one covering its first character usually does not,
 * and restoring to it lands on the page before.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class SavedPageAnchorTest {
    @Test
    fun `a saved page anchors on a fragment that begins on it`() {
        // One long paragraph of numbered sentences, laid out narrow enough
        // that every page break falls inside a sentence.
        val sentences = (0 until 40).map { "Sentence number $it rambles on for long enough to wrap onto another line. " }
        val chapter = handBuiltSentences(sentences) { "s$it" }
        val layout = laidOut(chapter, 200.0, 120.0)
        assertTrue(layout.pages.size > 2)

        var straddles = false
        for (page in layout.pages.drop(1).filter { it.characterRange.length > 0 }) {
            val start = page.characterRange.location
            val covering = chapter.fragmentIdAt(start)
            val coveringRange = covering?.let { chapter.fragmentRanges[it] }
            if (coveringRange != null && coveringRange.location < start) straddles = true
            val anchor = layout.firstFragment(page)
            if (anchor != null) {
                val range = chapter.fragmentRanges.getValue(anchor)
                assertTrue("$anchor began before page ${page.index}", range.location >= start)
                assertTrue(range.location in page.characterRange)
                // What a restore does with it: back to this page, never the one before.
                val locator = ReadiumLocator(
                    href = "ch.xhtml", type = "application/xhtml+xml",
                    locations = ReadiumLocator.Locations(fragments = listOf(anchor), charOffset = start),
                )
                val offset = LocatorAnchoring.characterOffset(locator, chapter.text, chapter.fragmentRanges)!!
                assertEquals(page.index, layout.pageContainingOffset(offset)?.index)
            }
            // The covering fragment is the trap: whenever it began earlier it
            // must not have been chosen.
            if (coveringRange != null && coveringRange.location < start) assertTrue(anchor != covering)
        }
        assertTrue("no page break fell inside a sentence; the fixture proves nothing", straddles)
    }
}

/** The drawing entry point the reader screen calls: paper, marks, then text. */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class PageDrawingTest {
    @Test
    fun `a page draws its paper, its narrated sentence and its text`() {
        val chapter = readalongChapter()
        val layout = ChapterLayout(chapter, ReaderStyle(theme = ReaderTheme.SEPIA), testFonts)
        layout.layout(340.0, 560.0)
        val page = layout.pageContainingFragment("ch01-s1")!!
        val bitmap = Bitmap.createBitmap(340, 560, Bitmap.Config.ARGB_8888)
        PageDrawing.draw(
            Canvas(bitmap), layout, page,
            marks = listOf(PageDrawing.narration(layout, "ch01-s1", page, ReaderTheme.SEPIA.highlight)),
            theme = ReaderTheme.SEPIA,
        )
        // The paper is sepia where nothing is drawn.
        assertEquals(ReaderTheme.SEPIA.background.argb, bitmap.getPixel(339, 559))
        // The mark is under the sentence: a point inside its first rectangle,
        // between glyphs or not, is no longer plain paper.
        val rect = layout.highlightRects("ch01-s1", page).first()
        val tinted = (rect.minX.toInt() + 1 until rect.maxX.toInt() - 1).count { x ->
            bitmap.getPixel(x, (rect.minY + 2).toInt()) != ReaderTheme.SEPIA.background.argb
        }
        assertTrue("the narrated sentence carries no mark", tinted > (rect.width * 0.8).toInt())
        bitmap.captureRoboImage("build/outputs/roborazzi/page.png")
    }

    @Test
    fun `the Android path of an empty block is empty`() {
        val path: Path = HighlightBlock.path(lines = emptyList(), style = HighlightBlock.Style.forFontSize(18.0)).toAndroidPath()
        assertTrue(path.isEmpty)
    }
}
