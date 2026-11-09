package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * In-book plates: sized from the header when the chapter is parsed, decoded
 * only when drawn. Ported from `ArchiveImageSourceTests.swift`: the sizing
 * half and the decode-once rule. The decode itself is `:render-android`'s
 * (`PlateDecodingTest` there holds the 4096-pixel bound).
 */
class ArchiveImageSourceTest {
    @Test
    fun `an ordinary plate keeps the size it always had`() {
        val source = ArchiveImageSource(storedArchive(listOf("OEBPS/images/plate.png" to encodedImage(800, 3000))))
        val plate = source.image("OEBPS/images/plate.png")
        assertNotNull(plate)
        plate!!
        // `layoutWidth` and `layoutHeight` are what the parser scales a plate
        // by, so this is what keeps every illustrated page laid out as it was.
        assertEquals(800.0, plate.layoutWidth, 0.0)
        assertEquals(3000.0, plate.layoutHeight, 0.0)
    }

    @Test
    fun `a missing or undecodable entry is no image`() {
        val source = ArchiveImageSource(storedArchive(listOf("OEBPS/images/broken.png" to "not a png".toByteArray())))
        assertNull(source.image("OEBPS/images/broken.png"))
        assertNull(source.image("OEBPS/images/absent.png"))
    }

    /** A chapter asks once per plate, and gets the same plate each time. */
    @Test
    fun `a plate is read once and kept`() {
        val source = ArchiveImageSource(storedArchive(listOf("a.png" to encodedImage(10, 10))))
        assertSame(source.image("a.png"), source.image("a.png"))
    }

    /**
     * The decode is handed in, and happens once however often the page is
     * drawn — a decode that failed is not retried on every redraw either.
     */
    @Test
    fun `a plate decodes once, and the source counts it`() {
        val source = ArchiveImageSource(storedArchive(listOf("a.png" to encodedImage(10, 10), "b.png" to encodedImage(5, 5))))
        val plate = source.image("a.png")!!
        var calls = 0
        repeat(3) { assertEquals("bitmap", plate.decoded { _, _ -> calls += 1; "bitmap" }) }
        assertEquals(1, calls)
        assertEquals(1, source.decodeCount)
        val failing = source.image("b.png")!!
        repeat(2) { assertNull(failing.decoded<String> { _, _ -> calls += 1; null }) }
        assertEquals(2, calls)
        assertEquals(2, source.decodeCount)
    }

    @Test
    fun `the decode is told the bound`() {
        val source = ArchiveImageSource(storedArchive(listOf("a.png" to encodedImage(10, 10))), maxPixelSize = 512)
        assertEquals(512, source.image("a.png")!!.decoded { _, bound -> bound })
        assertEquals(ArchiveImageSource.DEFAULT_MAX_PIXEL_SIZE, 4096)
    }
}

/**
 * What the bounded decode cost, and what it changed: the parser needs a
 * plate's size to lay a chapter out; only drawing needs its pixels. Ported from
 * `ArchiveImageSourceTests.swift`'s `PlateDecodingTests`, the parse half.
 */
class PlateDecodingTest {
    private val chapter =
        "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>\n" +
            "<p>Before.</p><img src=\"images/plate.png\" alt=\"A plate\"/><p>After.</p>\n</body></html>"

    private fun parse(source: ArchiveImageSource, maxImageWidth: Double = 320.0): StyledChapter =
        parse(chapter, baseHref = "OEBPS/chapter.xhtml", maxImageWidth = maxImageWidth, loadImage = { source.image(it) })

    @Test
    fun `parsing a chapter learns its plates' sizes without decoding one`() {
        val source = ArchiveImageSource(storedArchive(listOf("OEBPS/images/plate.png" to encodedImage(200, 300))))
        val result = parse(source)
        val plate = result.plates.single()
        assertEquals(200.0, plate.displayWidth, 0.0)
        assertEquals(300.0, plate.displayHeight, 0.0)
        // What search and the Ask index do with every chapter of the book.
        assertEquals("a parse decoded ${source.decodeCount} plates", 0, source.decodeCount)
        assertTrue("Before.\n\uFFFC\nAfter." == result.text)
    }

    /**
     * R-59, on the iPhone's terms. `UIImage(data:)` reports a plate's size in
     * pixels whatever resolution it is tagged with, and the iPhone and iPad
     * are the size Android follows; only the Mac's `NSImage` scaled by DPI.
     * So a high-resolution plate past the decode bound is laid out at its own
     * pixel size, not at the bounded bitmap's.
     */
    @Test
    fun `a high-resolution plate past the bound keeps its size`() {
        for ((width, height, dpi) in listOf(Triple(6000, 40, 300.0), Triple(5000, 30, 144.0), Triple(800, 600, 300.0), Triple(800, 600, 72.0))) {
            val source = ArchiveImageSource(storedArchive(listOf("OEBPS/images/plate.png" to pngTagged(width, height, dpi))))
            // A column wide enough that nothing is scaled to fit it: the size
            // laid out is the size the source reported.
            val plate = parse(source, maxImageWidth = 100_000.0).plates.single()
            assertEquals(width.toDouble(), plate.displayWidth, 0.5)
            assertEquals(height.toDouble(), plate.displayHeight, 0.5)
        }
    }
}
