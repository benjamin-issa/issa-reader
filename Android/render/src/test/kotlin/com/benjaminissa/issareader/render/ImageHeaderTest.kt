package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.io.ByteArrayOutputStream

/**
 * Sizes read from headers alone, as ImageIO's `CGImageSourceCopyPropertiesAtIndex`
 * reads them for the Swift client — because whether a plate is in the string
 * at all is decided by whether its header has a size. There is no Swift suite
 * of this name: on the Mac this is ImageIO's job. The cases are the formats a
 * book carries, built here byte by byte or with the JDK's own encoders.
 */
class ImageHeaderTest {
    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }
    private fun be16(value: Int) = bytes(value ushr 8, value)
    private fun be32(value: Long) = ByteArray(4) { ((value ushr ((3 - it) * 8)) and 0xFF).toByte() }
    private fun le16(value: Int) = bytes(value, value ushr 8)
    private fun le24(value: Int) = bytes(value, value ushr 8, value ushr 16)
    private fun le32(value: Long) = ByteArray(4) { ((value ushr (it * 8)) and 0xFF).toByte() }
    private fun ascii(text: String) = text.toByteArray(Charsets.US_ASCII)

    private fun box(type: String, vararg body: ByteArray): ByteArray {
        val content = body.fold(ByteArray(0)) { all, part -> all + part }
        return be32(8L + content.size) + ascii(type) + content
    }

    private fun size(data: ByteArray): Pair<Double, Double>? =
        ImageHeader.read(data)?.let { it.layoutWidth to it.layoutHeight }

    @Test
    fun `the JDK's own encodings are sized`() {
        for (format in listOf("png", "jpg", "gif", "bmp", "tiff")) {
            assertEquals(format, 37.0 to 23.0, size(encodedImage(37, 23, format)))
        }
    }

    @Test
    fun `a PNG is sized by its IHDR, also behind Apple's CgBI chunk`() {
        val png = encodedImage(640, 480, "png")
        assertEquals(ImageHeader.Format.PNG, ImageHeader.read(png)?.format)
        // A crushed PNG: CgBI (4 bytes of data) between the signature and IHDR.
        val crushed = png.copyOfRange(0, 8) + be32(4) + ascii("CgBI") + bytes(0x50, 0, 0x20, 2) + be32(0) +
            png.copyOfRange(8, png.size)
        assertEquals(640.0 to 480.0, size(crushed))
    }

    /** ImageIO turns EXIF orientations 5 to 8 upright, so a portrait photograph is laid out portrait. */
    @Test
    fun `a JPEG's EXIF orientation turns its size upright`() {
        val jpeg = encodedImage(300, 200, "jpg")
        for ((orientation, expected) in listOf(1 to (300.0 to 200.0), 3 to (300.0 to 200.0), 6 to (200.0 to 300.0), 8 to (200.0 to 300.0))) {
            val tiff = ascii("MM") + be16(42) + be32(8) + be16(1) +
                be16(0x0112) + be16(3) + be32(1) + be16(orientation) + be16(0) + be32(0)
            val exif = ascii("Exif") + bytes(0, 0) + tiff
            val app1 = bytes(0xFF, 0xE1) + be16(exif.size + 2) + exif
            val tagged = jpeg.copyOfRange(0, 2) + app1 + jpeg.copyOfRange(2, jpeg.size)
            assertEquals("orientation $orientation", expected, size(tagged))
            assertEquals(orientation, ImageHeader.read(tagged)?.orientation)
        }
    }

    @Test
    fun `a progressive JPEG, and one with fill bytes before its markers, are sized`() {
        val sof2 = bytes(0xFF, 0xD8, 0xFF, 0xFF, 0xFF, 0xC2) + be16(17) + bytes(8) + be16(90) + be16(120) +
            bytes(3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1)
        assertEquals(120.0 to 90.0, size(sof2))
    }

    @Test
    fun `a TIFF's orientation is honoured`() {
        val tiff = ascii("II") + le16(42) + le32(8) + le16(3) +
            le16(256) + le16(3) + le32(1) + le16(1000) + le16(0) +
            le16(257) + le16(4) + le32(1) + le32(400) +
            le16(274) + le16(3) + le32(1) + le16(6) + le16(0) + le32(0)
        assertEquals(400.0 to 1000.0, size(tiff))
    }

    @Test
    fun `the three WebP encodings are sized`() {
        fun riff(chunk: String, payload: ByteArray) =
            ascii("RIFF") + le32(4L + 8 + payload.size) + ascii("WEBP") + ascii(chunk) + le32(payload.size.toLong()) + payload
        val lossy = riff("VP8 ", bytes(0x10, 0x02, 0x00, 0x9D, 0x01, 0x2A) + le16(500) + le16(333) + ByteArray(10))
        assertEquals(500.0 to 333.0, size(lossy))
        val bits = (499L) or (332L shl 14)
        val lossless = riff("VP8L", bytes(0x2F) + le32(bits) + ByteArray(4))
        assertEquals(500.0 to 333.0, size(lossless))
        val extended = riff("VP8X", bytes(0x10, 0, 0, 0) + le24(4999) + le24(3332))
        assertEquals(5000.0 to 3333.0, size(extended))
    }

    /** The primary item's `ispe`, turned by its `irot`: a quarter turn swaps the sides. */
    @Test
    fun `a HEIF or AVIF is sized by its primary item`() {
        for ((brand, rotation, expected) in listOf(
            Triple("heic", 0, 4032.0 to 3024.0),
            Triple("heic", 1, 3024.0 to 4032.0),
            Triple("avif", 3, 3024.0 to 4032.0),
            Triple("mif1", 2, 4032.0 to 3024.0),
        )) {
            val ftyp = box("ftyp", ascii(brand), be32(0), ascii("mif1"), ascii(brand))
            val pitm = box("pitm", be32(0), be16(2))
            // Item 1 is a thumbnail at another size; item 2 is the primary.
            val ipco = box(
                "ipco",
                box("ispe", be32(0), be32(320), be32(240)),
                box("ispe", be32(0), be32(4032), be32(3024)),
                box("irot", bytes(rotation)),
            )
            val ipma = box(
                "ipma", be32(0), be32(2),
                be16(1), bytes(1, 0x81),
                be16(2), bytes(2, 0x82, 0x03),
            )
            val meta = box("meta", be32(0), box("hdlr", be32(0), be32(0), ascii("pict"), ByteArray(13)), pitm, box("iprp", ipco, ipma))
            assertEquals("$brand irot $rotation", expected, size(ftyp + meta + box("mdat", ByteArray(4))))
        }
        // An ISO media file that is not an image is not sized.
        assertNull(size(box("ftyp", ascii("isom"), be32(0), ascii("mp41")) + box("moov")))
    }

    @Test
    fun `an ICO is sized by its first image, 0 meaning 256`() {
        val ico = bytes(0, 0, 1, 0) + le16(1) + bytes(0, 0, 0, 0) + le16(1) + le16(32) + le32(40) + le32(22) + ByteArray(40)
        assertEquals(256.0 to 256.0, size(ico))
        // One whose image is stored as a PNG is that PNG's size.
        val png = encodedImage(48, 40, "png")
        val embedded = bytes(0, 0, 1, 0) + le16(1) + bytes(48, 40, 0, 0) + le16(1) + le16(32) +
            le32(png.size.toLong()) + le32(22) + png
        assertEquals(48.0 to 40.0, size(embedded))
    }

    @Test
    fun `a JPEG 2000 file and a bare codestream are sized`() {
        val siz = bytes(0xFF, 0x4F, 0xFF, 0x51) + be16(41) + be16(0) + be32(1100) + be32(800) + be32(100) + be32(0) +
            be32(1100) + be32(800) + be32(0) + be32(0) + be16(3)
        assertEquals(1000.0 to 800.0, size(siz))
        val jp2 = bytes(0, 0, 0, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A) +
            box("ftyp", ascii("jp2 "), be32(0), ascii("jp2 ")) +
            box("jp2h", box("ihdr", be32(700), be32(900), be16(3), bytes(7, 7, 0, 0))) +
            box("jp2c", siz)
        assertEquals(900.0 to 700.0, size(jp2))
    }

    @Test
    fun `a PSD is sized`() {
        val psd = ascii("8BPS") + be16(1) + ByteArray(6) + be16(3) + be32(480) + be32(640) + be16(8) + be16(3)
        assertEquals(640.0 to 480.0, size(psd))
    }

    /** SVG is no plate on the iPhone — ImageIO cannot size it — so it is no plate here. */
    @Test
    fun `what ImageIO cannot size is not sized`() {
        assertNull(size(ascii("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>")))
        assertNull(size(ascii("not a png")))
        assertNull(size(ByteArray(0)))
        // Truncated before the size.
        assertNull(size(encodedImage(10, 10, "png").copyOfRange(0, 20)))
        assertNull(size(bytes(0xFF, 0xD8, 0xFF, 0xE0, 0x00)))
        // A GIF with no frame in it has no image at all.
        val out = ByteArrayOutputStream()
        out.write(ascii("GIF89a") + le16(10) + le16(10) + bytes(0, 0, 0) + bytes(0x3B))
        assertNull(size(out.toByteArray()))
    }

    @Test
    fun `a zero-sized image is no image`() {
        val png = encodedImage(10, 10, "png")
        val zero = png.copyOfRange(0, 16) + be32(0) + png.copyOfRange(20, png.size)
        assertNull(size(zero))
    }
}
