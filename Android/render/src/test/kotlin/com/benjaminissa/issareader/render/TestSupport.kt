package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubArchive
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.EpubStyleSheet
import com.benjaminissa.issareader.testing.Fixtures
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.util.zip.CRC32
import javax.imageio.ImageIO

/** A book in `Packages/IssaRender/Tests/Fixtures`, read in place: `renderFixture("alice")`. */
internal fun renderFixture(name: String): EpubPackage = EpubPackage.open(Fixtures.render("$name.epub"))

/** Parses a chapter given as a string, as most of the Swift suites do. */
internal fun parse(
    html: String,
    style: ReaderStyle = ReaderStyle(),
    baseHref: String = "c.xhtml",
    maxImageWidth: Double = 320.0,
    maxImageHeight: Double = Double.MAX_VALUE,
    columnWidth: Double = 320.0,
    loadImage: ((String) -> ChapterArtwork?)? = null,
    loadStyleSheet: ((String) -> EpubStyleSheet?)? = null,
): StyledChapter = ChapterParser(
    style = style, maxImageWidth = maxImageWidth, maxImageHeight = maxImageHeight, columnWidth = columnWidth,
    loadImage = loadImage, loadStyleSheet = loadStyleSheet,
).parse(html.toByteArray(Charsets.UTF_8), baseHref)

/** The run over the character at [index]; the attributes `NSAttributedString.attribute(_:at:)` would read. */
internal fun StyledChapter.style(index: Int): RunStyle =
    runAt(index)?.style ?: throw AssertionError("no run at $index of ${text.length}")

/** The first chapter of a book whose rendered text is longer than [minimum]. */
internal fun firstChapterLongerThan(
    book: EpubPackage,
    minimum: Int,
    style: ReaderStyle = ReaderStyle(),
): StyledChapter {
    for (item in book.spine) {
        val parsed = ChapterParser(style).parse(book.archive.read(item.href), item.href)
        if (parsed.text.length > minimum) return parsed
    }
    throw AssertionError("no chapter longer than $minimum")
}

/**
 * The smallest ZIP [EpubArchive] reads: stored entries and a central
 * directory. The archive's own tests cover the hostile shapes.
 */
internal fun storedArchive(entries: List<Pair<String, ByteArray>>): EpubArchive {
    fun le16(value: Int) = byteArrayOf((value and 0xFF).toByte(), ((value ushr 8) and 0xFF).toByte())
    fun le32(value: Int) = ByteArray(4) { ((value ushr (it * 8)) and 0xFF).toByte() }
    val out = ByteArrayOutputStream()
    val central = ByteArrayOutputStream()
    for ((path, payload) in entries) {
        val name = path.toByteArray(Charsets.UTF_8)
        val offset = out.size()
        val crc = CRC32().apply { update(payload) }.value.toInt()
        out.write(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
        out.write(le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
        out.write(le32(crc) + le32(payload.size) + le32(payload.size))
        out.write(le16(name.size) + le16(0))
        out.write(name)
        out.write(payload)

        central.write(byteArrayOf(0x50, 0x4B, 0x01, 0x02))
        central.write(le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0))
        central.write(le32(crc) + le32(payload.size) + le32(payload.size))
        central.write(le16(name.size) + le16(0) + le16(0) + le16(0) + le16(0))
        central.write(le32(0) + le32(offset))
        central.write(name)
    }
    val directoryOffset = out.size()
    val directory = central.toByteArray()
    out.write(directory)
    out.write(byteArrayOf(0x50, 0x4B, 0x05, 0x06))
    out.write(le16(0) + le16(0) + le16(entries.size) + le16(entries.size))
    out.write(le32(directory.size) + le32(directoryOffset) + le16(0))
    return EpubArchive(out.toByteArray())
}

/**
 * An image of an exact pixel size, built rather than shipped: the sizes that
 * matter are the awkward ones, and shipping such a file to assert arithmetic
 * about it would be worse than making one.
 */
internal fun encodedImage(width: Int, height: Int, format: String = "png"): ByteArray {
    val type = if (format == "jpg" || format == "bmp") BufferedImage.TYPE_INT_RGB else BufferedImage.TYPE_INT_ARGB
    val image = BufferedImage(width, height, type)
    val graphics = image.createGraphics()
    graphics.color = java.awt.Color(51, 102, 153)
    graphics.fillRect(0, 0, width, height)
    graphics.dispose()
    val out = ByteArrayOutputStream()
    check(ImageIO.write(image, format, out)) { "no writer for $format" }
    return out.toByteArray()
}

/** [png] with a `pHYs` chunk saying it is [dpi] dots per inch, after IHDR. */
internal fun pngTagged(width: Int, height: Int, dpi: Double): ByteArray {
    val png = encodedImage(width, height, "png")
    val perMetre = Math.round(dpi / 0.0254).toInt()
    fun be32(value: Int) = ByteArray(4) { ((value ushr ((3 - it) * 8)) and 0xFF).toByte() }
    val body = "pHYs".toByteArray() + be32(perMetre) + be32(perMetre) + byteArrayOf(1)
    val crc = CRC32().apply { update(body) }.value.toInt()
    val chunk = be32(9) + body + be32(crc)
    // Signature (8) and IHDR (4 + 4 + 13 + 4).
    val split = 8 + 25
    return png.copyOfRange(0, split) + chunk + png.copyOfRange(split, png.size)
}
