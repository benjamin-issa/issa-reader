package com.benjaminissa.issareader.render.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import com.benjaminissa.issareader.render.ArchiveImageSource
import com.benjaminissa.issareader.render.ChapterParser
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.testing.Fixtures
import com.benjaminissa.issareader.epub.EpubArchive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import kotlin.math.ceil
import kotlin.math.roundToInt

/**
 * Rendering tests that actually rasterise. Ported from `DrawingTests.swift`.
 * A pagination test can pass while nothing is drawn on screen; only counting
 * pixels distinguishes "this page is genuinely empty" from "the draw path is
 * broken".
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class DrawingTest {
    @Test
    fun `a chapter with prose actually rasterises glyphs`() {
        val chapter = readalongChapter()
        assertTrue("fixture chapter should have prose", chapter.text.length > 100)
        val layout = laidOut(chapter, 340.0, 560.0)
        val coverage = inkCoverage(layout, layout.pages.first())
        assertTrue("page rendered no visible glyphs (coverage $coverage)", coverage > 0.005)
    }

    @Test
    fun `a real book's prose chapter rasterises too`() {
        val layout = laidOut(aliceChapterLongerThan(2000), 340.0, 560.0)
        assertTrue(inkCoverage(layout, layout.pages.first()) > 0.01)
    }

    /** Documented, not asserted as good or bad: why the reader must open on the first chapter with content rather than spine item zero. */
    @Test
    fun `the first spine item of a Gutenberg book is often a coverless title page`() {
        val book = renderFixture("alice")
        val first = book.spine[0]
        val parsed = ChapterParser(ReaderStyle()).parse(book.archive.read(first.href), first.href)
        println("first spine item ${first.href} has ${parsed.text.length} characters, ${parsed.complexity.imageCount} images")
        assertTrue(parsed.text.length >= 0)
    }
}

/**
 * Illustrations must occupy real space and actually paint. Ported from
 * `DrawingTests.swift`'s `ImageRenderingTests`.
 *
 * Every Gutenberg book opens on a cover wrapper that is nothing but an image,
 * so "renders no image" and "renders an empty chapter" look identical from
 * the outside — which is exactly how the blank first page shipped once already.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class ImageRenderingTest {
    private fun aliceCoverChapter() = renderFixture("alice").let { book ->
        val item = book.spine[0]
        ChapterParser(
            ReaderStyle(), maxImageWidth = 300.0,
            loadImage = { href ->
                try {
                    BitmapFactory.decodeByteArray(book.archive.read(href).let { it }, 0, book.archive.read(href).size)?.let(::BitmapArtwork)
                } catch (_: Exception) {
                    null
                }
            },
        ).parse(book.archive.read(item.href), item.href)
    }

    @Test
    fun `a cover-only chapter is no longer empty`() {
        val parsed = aliceCoverChapter()
        assertTrue(parsed.complexity.imageCount > 0)
        // The object-replacement character stands in for the illustration.
        assertTrue(parsed.text.contains('\uFFFC'))
        assertTrue("no image href recorded", parsed.runs.any { it.style.imageHref != null })
    }

    @Test
    fun `the illustration actually rasterises`() {
        val layout = laidOut(aliceCoverChapter(), 340.0, 560.0)
        val coverage = inkCoverage(layout, layout.pages.first())
        assertTrue("cover illustration did not paint (coverage $coverage)", coverage > 0.02)
    }

    @Test
    fun `an image with no resolver is skipped rather than reserving empty space`() {
        val result = parse("<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n<p>Before.</p><img src=\"missing.png\"/><p>After.</p>\n</body></html>")
        assertEquals(1, result.complexity.imageCount)
        // Counted, but nothing reserved: a box with no picture in it is worse than no box.
        assertFalse(result.text.contains('\uFFFC'))
        assertTrue(result.text.contains("Before."))
        assertTrue(result.text.contains("After."))
    }
}

/**
 * The clip that keeps a straddling paragraph's lines on the right page.
 * Ported from `DrawingTests.swift`'s `StraddlingParagraphDrawTests`.
 *
 * A page's last paragraph may continue onto the next page, and drawing it
 * whole draws lines that belong to the *next* page as well: visible past the
 * bottom of the page, then drawn *again* when that page's turn comes. A
 * pagination-only test cannot see this — it never rasterises.
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class StraddlingParagraphDrawTest {
    private val pageHeight = 400.0
    private val pageWidth = 320

    private fun render(layout: ChapterLayout, page: com.benjaminissa.issareader.render.RenderedPage): Bitmap =
        render(layout, page, pageWidth, pageHeight.toInt())

    /**
     * A page in the middle of the giant paragraph: its predecessor and its
     * successor belong to the same paragraph, so this is squarely the
     * straddling case. Deliberately not page 0, whose `yOffset` of 0 once
     * made a clip anchored at the wrong origin look correct by coincidence —
     * and the first assertion checks there *is* ink above the bottom, because
     * a page with none anywhere trivially has none below it either.
     */
    @Test
    fun `nothing is drawn below where a page's own content actually ends`() {
        val layout = PageBoundaryTest.oneGiantParagraphLayout(pageHeight)
        val page = layout.pages.drop(1).dropLast(1).first()
        val localContentBottom = ceil(page.contentBottom - page.yOffset).toInt()
        assertTrue("the fixture should leave a real margin to check", localContentBottom < pageHeight.toInt())
        val pixels = render(layout, page)
        assertTrue(
            "no row above content-bottom $localContentBottom has any ink — the page drew nothing at all",
            (0 until localContentBottom).any { rowHasInk(pixels, it) },
        )
        for (y in localContentBottom until pageHeight.toInt()) {
            assertFalse("row $y has ink below content-bottom $localContentBottom — the next page's lines leaked through", rowHasInk(pixels, y))
        }
    }

    @Test
    fun `consecutive pages of a straddling paragraph do not repeat the same line`() {
        val layout = PageBoundaryTest.oneGiantParagraphLayout(pageHeight)
        val page = layout.pages.drop(1).dropLast(1).first()
        assertTrue("the fixture should have a following page", page.index + 1 < layout.pages.size)
        // The first row of the next page, in this page's own coordinates, is
        // this page's content-bottom — if that row shows ink here, this page
        // drew a line the next page will draw too.
        val seam = (page.contentBottom - page.yOffset).roundToInt()
        if (seam >= pageHeight.toInt()) return
        assertFalse("page ${page.index} painted its own seam row", rowHasInk(render(layout, page), seam))
    }
}

/**
 * In-book plates are decoded at a bounded size, and only when drawn. Ported
 * from `ArchiveImageSourceTests.swift`: the decoding half (the sizing half is
 * `:render`'s `ArchiveImageSourceTest`).
 */
@RunWith(RobolectricTestRunner::class)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@Config(sdk = [36])
class PlateDecodingTest {
    private fun png(width: Int, height: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        Canvas(bitmap).drawColor(Color.rgb(51, 102, 153))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        return out.toByteArray()
    }

    /** The smallest ZIP the archive reads: stored entries and a central directory. */
    private fun archive(entries: List<Pair<String, ByteArray>>): EpubArchive {
        fun le16(value: Int) = byteArrayOf((value and 0xFF).toByte(), ((value ushr 8) and 0xFF).toByte())
        fun le32(value: Int) = ByteArray(4) { ((value ushr (it * 8)) and 0xFF).toByte() }
        val out = ByteArrayOutputStream()
        val central = ByteArrayOutputStream()
        for ((path, payload) in entries) {
            val name = path.toByteArray()
            val offset = out.size()
            val crc = CRC32().apply { update(payload) }.value.toInt()
            out.write(byteArrayOf(0x50, 0x4B, 0x03, 0x04) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            out.write(le32(crc) + le32(payload.size) + le32(payload.size) + le16(name.size) + le16(0) + name + payload)
            central.write(byteArrayOf(0x50, 0x4B, 0x01, 0x02) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
            central.write(le32(crc) + le32(payload.size) + le32(payload.size) + le16(name.size) + le16(0) + le16(0) + le16(0) + le16(0))
            central.write(le32(0) + le32(offset) + name)
        }
        val directoryOffset = out.size()
        val directory = central.toByteArray()
        out.write(directory)
        out.write(byteArrayOf(0x50, 0x4B, 0x05, 0x06) + le16(0) + le16(0) + le16(entries.size) + le16(entries.size))
        out.write(le32(directory.size) + le32(directoryOffset) + le16(0))
        return EpubArchive(out.toByteArray())
    }

    private val chapter = "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n" +
        "<p>Before.</p><img src=\"images/plate.png\" alt=\"A plate\"/><p>After.</p>\n</body></html>"

    @Test
    fun `a 15000-pixel plate decodes to at most 4096 pixels`() {
        // A strip rather than a square: the bound is on the longer side, and
        // building a 15000-pixel square would itself cost the memory this
        // exists to save.
        val source = ArchiveImageSource(archive(listOf("OEBPS/images/plate.png" to png(15000, 30))))
        val plate = source.image("OEBPS/images/plate.png")!!
        val bitmap = PlateBitmaps.bitmap(plate)!!
        assertTrue("decoded at ${bitmap.width}×${bitmap.height}", maxOf(bitmap.width, bitmap.height) <= 4096)
        assertTrue("bounded, not shrunk further", bitmap.width > 4000)
    }

    @Test
    fun `an ordinary plate keeps the size it always had`() {
        val source = ArchiveImageSource(archive(listOf("OEBPS/images/plate.png" to png(800, 3000))))
        val plate = source.image("OEBPS/images/plate.png")!!
        assertEquals(800.0, plate.layoutWidth, 0.0)
        assertEquals(3000.0, plate.layoutHeight, 0.0)
        val bitmap = PlateBitmaps.bitmap(plate)!!
        assertEquals(800 to 3000, bitmap.width to bitmap.height)
    }

    @Test
    fun `a plate is decoded once its page is drawn, and once only`() {
        val source = ArchiveImageSource(archive(listOf("OEBPS/images/plate.png" to png(200, 300))))
        val parsed = parse(chapter, baseHref = "OEBPS/chapter.xhtml", loadImage = { source.image(it) })
        val layout = laidOut(parsed, 340.0, 560.0)
        val page = layout.pages.first()
        // Laying a chapter out is not drawing it: the reader lays out every
        // page of a chapter at each open and each typeface step.
        assertEquals("laying the chapter out decoded its plate", 0, source.decodeCount)

        // The plate is a 200×300 block of one dark colour on a white page.
        val coverage = inkCoverage(layout, page)
        assertTrue("the plate did not paint (coverage $coverage)", coverage > 0.2)
        assertEquals(1, source.decodeCount)

        // Every narrated sentence and page turn redraws.
        inkCoverage(layout, page)
        assertEquals("a redraw decoded the plate again", 1, source.decodeCount)
    }

    /** A plate that drawn would overhang a narrower column than it was parsed for is scaled down to it at layout. */
    @Test
    fun `a plate never draws wider than the column it lands in`() {
        val source = ArchiveImageSource(archive(listOf("OEBPS/images/plate.png" to png(300, 100))))
        val parsed = parse(chapter, baseHref = "OEBPS/chapter.xhtml", maxImageWidth = 320.0, loadImage = { source.image(it) })
        val layout = laidOut(parsed, 150.0, 560.0)
        val offset = layout.text.indexOf('\uFFFC')
        val rects = layout.rects(com.benjaminissa.issareader.render.TextRange(offset, 1), layout.pages.first())
        assertTrue(rects.isNotEmpty())
        assertTrue("plate is ${rects.first().width} wide in a 150 column", rects.all { it.width <= 150.0 + 0.5 })
    }

    /** The decoder is real: the fixture book's cover, a JPEG, decodes to its own size. */
    @Test
    fun `a book's own plate decodes`() {
        val book = com.benjaminissa.issareader.epub.EpubPackage.open(Fixtures.render("alice.epub"))
        val source = ArchiveImageSource(book.archive)
        val href = book.manifest.values.first { it.mediaType.startsWith("image/") }.href
        val plate = source.image(href)!!
        val bitmap = PlateBitmaps.bitmap(plate)!!
        assertEquals(plate.layoutWidth.toInt(), bitmap.width)
        assertEquals(plate.layoutHeight.toInt(), bitmap.height)
    }
}
