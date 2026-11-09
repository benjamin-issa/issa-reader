package com.benjaminissa.issareader.render

/**
 * An image's pixel size and orientation, read from its header and nothing else.
 *
 * The Swift client asks ImageIO (`CGImageSourceCopyPropertiesAtIndex`), which
 * reads metadata and decodes nothing. This is that question answered in plain
 * Kotlin, for two reasons that both come down to the chapter's string:
 *
 * - **Whether a plate is in the text at all is decided here.** A plate puts an
 *   object-replacement character and a line break into the rendered string,
 *   and every saved position, Ask passage and spoiler boundary is an offset
 *   into that string. So the two clients must agree on which images have a
 *   size, and that cannot depend on whether this device happens to have a
 *   decoder for the format — `BitmapFactory` on an old Android has no HEIF,
 *   and a JVM has no WebP at all. Only the header decides.
 * - **The parse must not decode.** The in-book search and the Ask index parse
 *   every chapter of a book and never draw; decoding every plate to learn its
 *   size made both decode every illustration in the book.
 *
 * It reads the formats ImageIO reports a size for that a book can carry: JPEG,
 * PNG (and Apple's CgBI variant), GIF, WebP, BMP, TIFF, HEIF and AVIF, ICO and
 * CUR, JPEG 2000 (both the JP2 file and the bare codestream) and PSD. SVG is
 * deliberately absent, as it is for ImageIO and therefore for `UIImage(data:)`
 * on the iPhone: an SVG plate is not drawn there, and so is not in the string.
 */
data class ImageHeader(
    val format: Format,
    /** The stored width, before any orientation is applied. */
    val pixelWidth: Long,
    val pixelHeight: Long,
    /** The EXIF orientation, 1 to 8; 1 where the image says nothing. */
    val orientation: Int = 1,
) {
    enum class Format { JPEG, PNG, GIF, WEBP, BMP, TIFF, HEIF, ICO, JPEG2000, PSD }

    /**
     * The size `UIImage(data:)` reports, which is what the parser lays a plate
     * out by: pixels, turned upright. Orientations 5 to 8 are quarter turns,
     * as the decode turns the pixels (`kCGImageSourceCreateThumbnailWithTransform`).
     *
     * Pixels, not points at the image's resolution, because the iPhone and
     * iPad are the clients a position is most often shared with; the Mac's
     * `NSImage` scaled by DPI, and a plate tagged 300 DPI is laid out smaller
     * there. That changes a plate's height on the page, never the string.
     */
    val layoutWidth: Double get() = (if (isQuarterTurn) pixelHeight else pixelWidth).toDouble()
    val layoutHeight: Double get() = (if (isQuarterTurn) pixelWidth else pixelHeight).toDouble()

    val isQuarterTurn: Boolean get() = orientation in 5..8

    companion object {
        /**
         * The header of [data], or `null` when it is no image ImageIO would
         * size — unrecognised, truncated before the size, or sized zero.
         */
        fun read(data: ByteArray): ImageHeader? {
            val header = try {
                Bytes(data).sniff()
            } catch (_: IndexOutOfBoundsException) {
                // Truncated before the size: ImageIO has nothing to report.
                null
            } ?: return null
            if (header.pixelWidth <= 0 || header.pixelHeight <= 0) return null
            return header
        }
    }
}

/** Bounds-checked big- and little-endian reads; any read past the end throws, and [ImageHeader.read] turns that into `null`. */
private class Bytes(val data: ByteArray) {
    val size: Int get() = data.size

    fun u8(at: Int): Int {
        if (at < 0 || at >= data.size) throw IndexOutOfBoundsException()
        return data[at].toInt() and 0xFF
    }

    fun be16(at: Int): Int = (u8(at) shl 8) or u8(at + 1)
    fun le16(at: Int): Int = u8(at) or (u8(at + 1) shl 8)
    fun be32(at: Int): Long = (be16(at).toLong() shl 16) or be16(at + 2).toLong()
    fun le32(at: Int): Long = le16(at).toLong() or (le16(at + 2).toLong() shl 16)
    fun le24(at: Int): Int = u8(at) or (u8(at + 1) shl 8) or (u8(at + 2) shl 16)

    fun startsWith(at: Int, vararg bytes: Int): Boolean {
        if (at < 0 || at + bytes.size > data.size) return false
        return bytes.indices.all { u8(at + it) == bytes[it] }
    }

    fun ascii(at: Int, text: String): Boolean = startsWith(at, *text.map { it.code }.toIntArray())

    fun fourcc(at: Int): String = String(CharArray(4) { u8(at + it).toChar() })

    fun sniff(): ImageHeader? = when {
        startsWith(0, 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A) -> png()
        startsWith(0, 0xFF, 0xD8, 0xFF) -> jpeg()
        ascii(0, "GIF87a") || ascii(0, "GIF89a") -> gif()
        ascii(0, "RIFF") && ascii(8, "WEBP") -> webp()
        ascii(0, "BM") -> bmp()
        startsWith(0, 0x49, 0x49, 0x2A, 0x00) -> tiff(littleEndian = true)
        startsWith(0, 0x4D, 0x4D, 0x00, 0x2A) -> tiff(littleEndian = false)
        size >= 12 && ascii(4, "ftyp") -> heif()
        startsWith(0, 0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A) -> jp2()
        startsWith(0, 0xFF, 0x4F, 0xFF, 0x51) -> j2k(0)
        ascii(0, "8BPS") -> psd()
        startsWith(0, 0x00, 0x00, 0x01, 0x00) || startsWith(0, 0x00, 0x00, 0x02, 0x00) -> ico()
        else -> null
    }

    // PNG

    /**
     * IHDR's width and height. Apple's "crushed" PNG puts a `CgBI` chunk in
     * front of it, which ImageIO reads like any other, so the chunks are
     * walked rather than IHDR assumed at byte 12.
     */
    private fun png(): ImageHeader? {
        var at = 8
        repeat(4) {
            val length = be32(at)
            val type = fourcc(at + 4)
            if (type == "IHDR") return ImageHeader(ImageHeader.Format.PNG, be32(at + 8), be32(at + 12))
            if (length > Int.MAX_VALUE - at - 12) return null
            at += 12 + length.toInt()
        }
        return null
    }

    // JPEG

    /**
     * The first start-of-frame's dimensions, and the EXIF orientation if one
     * comes before it — which in a real file it always does, since APP1 sits
     * at the front. ImageIO honours that orientation, so the parser lays a
     * portrait photograph out portrait.
     */
    private fun jpeg(): ImageHeader? {
        var at = 2
        var orientation = 1
        while (true) {
            if (u8(at) != 0xFF) return null
            // Any number of fill bytes may precede a marker.
            var markerAt = at + 1
            while (u8(markerAt) == 0xFF) markerAt += 1
            val marker = u8(markerAt)
            at = markerAt + 1
            when (marker) {
                // Markers with no length: TEM, RSTn, SOI.
                0x01, in 0xD0..0xD8 -> continue
                // End of image, or start of scan with no frame before it.
                0xD9, 0xDA -> return null
            }
            val length = be16(at)
            if (length < 2) return null
            when (marker) {
                0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF -> {
                    val height = be16(at + 3)
                    val width = be16(at + 5)
                    return ImageHeader(ImageHeader.Format.JPEG, width.toLong(), height.toLong(), orientation)
                }
                0xE1 -> if (ascii(at + 2, "Exif") && startsWith(at + 6, 0, 0)) {
                    exifOrientation(at + 8, at + length)?.let { orientation = it }
                }
            }
            at += length
        }
    }

    /** The orientation tag (0x0112) of the TIFF structure at [start], bounded by [end]. */
    private fun exifOrientation(start: Int, end: Int): Int? = try {
        val little = when {
            startsWith(start, 0x49, 0x49, 0x2A, 0x00) -> true
            startsWith(start, 0x4D, 0x4D, 0x00, 0x2A) -> false
            else -> null
        } ?: return null
        val tiff = TiffReader(this, start, little, end)
        tiff.firstIfd()[0x0112]?.takeIf { it in 1..8 }?.toInt()
    } catch (_: IndexOutOfBoundsException) {
        // A damaged EXIF block costs the orientation, not the size.
        null
    }

    // GIF

    /**
     * The logical screen, which is the canvas ImageIO composes every frame
     * onto and reports as the image's size. A GIF with no frame in it has no
     * image at all; one whose screen says zero is sized by its first frame.
     */
    private fun gif(): ImageHeader? {
        val width = le16(6)
        val height = le16(8)
        val flags = u8(10)
        var at = 13
        if (flags and 0x80 != 0) at += 3 * (1 shl ((flags and 0x07) + 1))
        while (true) {
            when (u8(at)) {
                0x2C -> {
                    if (width > 0 && height > 0) {
                        return ImageHeader(ImageHeader.Format.GIF, width.toLong(), height.toLong())
                    }
                    return ImageHeader(ImageHeader.Format.GIF, le16(at + 5).toLong(), le16(at + 7).toLong())
                }
                0x21 -> {
                    at += 2
                    while (true) {
                        val block = u8(at)
                        at += 1 + block
                        if (block == 0) break
                    }
                }
                else -> return null
            }
        }
    }

    // WebP

    private fun webp(): ImageHeader? = when (fourcc(12)) {
        // Lossy: the frame header after the three-byte tag and the start code.
        "VP8 " -> if (startsWith(23, 0x9D, 0x01, 0x2A)) {
            ImageHeader(ImageHeader.Format.WEBP, (le16(26) and 0x3FFF).toLong(), (le16(28) and 0x3FFF).toLong())
        } else {
            null
        }
        // Lossless: fourteen bits each, stored minus one.
        "VP8L" -> if (u8(20) == 0x2F) {
            val bits = le32(21)
            ImageHeader(ImageHeader.Format.WEBP, (bits and 0x3FFF) + 1, ((bits shr 14) and 0x3FFF) + 1)
        } else {
            null
        }
        // Extended: the canvas, twenty-four bits each, stored minus one.
        "VP8X" -> ImageHeader(ImageHeader.Format.WEBP, le24(24).toLong() + 1, le24(27).toLong() + 1)
        else -> null
    }

    // BMP

    /** A negative height is a top-down bitmap, the same size. */
    private fun bmp(): ImageHeader? {
        val headerSize = le32(14)
        return if (headerSize == 12L) {
            ImageHeader(ImageHeader.Format.BMP, le16(18).toLong(), le16(20).toLong())
        } else if (headerSize >= 16) {
            val width = le32(18).toInt()
            val height = le32(22).toInt()
            if (width <= 0) null else ImageHeader(ImageHeader.Format.BMP, width.toLong(), kotlin.math.abs(height.toLong()))
        } else {
            null
        }
    }

    // TIFF

    private fun tiff(littleEndian: Boolean): ImageHeader? {
        val ifd = TiffReader(this, 0, littleEndian, size).firstIfd()
        val width = ifd[0x0100] ?: return null
        val height = ifd[0x0101] ?: return null
        val orientation = ifd[0x0112]?.takeIf { it in 1..8 }?.toInt() ?: 1
        return ImageHeader(ImageHeader.Format.TIFF, width, height, orientation)
    }

    // HEIF and AVIF

    /**
     * The primary item's `ispe`, turned by its `irot`.
     *
     * ISO base media boxes: `ftyp` says which brand, `meta` holds the item
     * table — `pitm` names the primary item, `ipco` lists the properties and
     * `ipma` says which belong to which item. A grid's own `ispe` is the whole
     * picture, which is the size ImageIO reports for it.
     */
    private fun heif(): ImageHeader? {
        val ftypSize = be32(0).toInt()
        if (ftypSize < 16 || ftypSize > size) return null
        val brands = buildList {
            add(fourcc(8))
            var at = 16
            while (at + 4 <= ftypSize) {
                add(fourcc(at))
                at += 4
            }
        }
        if (brands.none { it in heifBrands }) return null

        val meta = boxes(ftypSize, size).firstOrNull { it.type == "meta" } ?: return null
        // `meta` is a full box: four bytes of version and flags before its children.
        val children = boxes(meta.bodyStart + 4, meta.end)
        val pitm = children.firstOrNull { it.type == "pitm" } ?: return null
        val primary = if (u8(pitm.bodyStart) == 0) be16(pitm.bodyStart + 4).toLong() else be32(pitm.bodyStart + 4)
        val iprp = children.firstOrNull { it.type == "iprp" } ?: return null
        val properties = boxes(iprp.bodyStart, iprp.end)
        val ipco = properties.firstOrNull { it.type == "ipco" } ?: return null
        val listed = boxes(ipco.bodyStart, ipco.end)

        val associated = ArrayList<Int>()
        for (ipma in properties.filter { it.type == "ipma" }) {
            val version = u8(ipma.bodyStart)
            val wideIndices = (u8(ipma.bodyStart + 3) and 1) != 0
            var at = ipma.bodyStart + 4
            val count = be32(at)
            at += 4
            for (entry in 0L until count) {
                val item = if (version < 1) be16(at).toLong().also { at += 2 } else be32(at).also { at += 4 }
                val associations = u8(at)
                at += 1
                repeat(associations) {
                    val index = if (wideIndices) (be16(at) and 0x7FFF).also { at += 2 } else (u8(at) and 0x7F).also { at += 1 }
                    if (item == primary && index > 0) associated.add(index)
                }
                if (at > ipma.end) return null
            }
        }
        var width = 0L
        var height = 0L
        var rotation = 0
        var mirrored = false
        for (index in associated) {
            val property = listed.getOrNull(index - 1) ?: continue
            when (property.type) {
                "ispe" -> {
                    width = be32(property.bodyStart + 4)
                    height = be32(property.bodyStart + 8)
                }
                "irot" -> rotation = u8(property.bodyStart) and 0x03
                "imir" -> mirrored = true
            }
        }
        if (width == 0L || height == 0L) return null
        // `irot` turns anticlockwise in quarter turns; EXIF's numbering says
        // the same thing from the other side. Only whether it is a quarter
        // turn reaches the layout.
        val orientation = when (rotation) {
            1 -> if (mirrored) 7 else 8
            2 -> if (mirrored) 4 else 3
            3 -> if (mirrored) 5 else 6
            else -> if (mirrored) 2 else 1
        }
        return ImageHeader(ImageHeader.Format.HEIF, width, height, orientation)
    }

    private class Box(val type: String, val bodyStart: Int, val end: Int)

    /** The boxes laid end to end between [start] and [end]. */
    private fun boxes(start: Int, end: Int): List<Box> {
        val found = ArrayList<Box>()
        var at = start
        while (at + 8 <= end) {
            var length = be32(at)
            val type = fourcc(at + 4)
            var body = at + 8
            when (length) {
                0L -> length = (end - at).toLong()
                1L -> {
                    val large = (be32(at + 8) shl 32) or be32(at + 12)
                    length = large
                    body = at + 16
                }
            }
            if (length < body - at || at + length > end) break
            found.add(Box(type, body, (at + length).toInt()))
            at += length.toInt()
        }
        return found
    }

    // JPEG 2000

    /** A JP2 file: its `jp2h` header box holds `ihdr`, height before width. */
    private fun jp2(): ImageHeader? {
        val header = boxes(0, size).firstOrNull { it.type == "jp2h" }
        if (header != null) {
            val ihdr = boxes(header.bodyStart, header.end).firstOrNull { it.type == "ihdr" } ?: return null
            return ImageHeader(ImageHeader.Format.JPEG2000, be32(ihdr.bodyStart + 4), be32(ihdr.bodyStart))
        }
        val codestream = boxes(0, size).firstOrNull { it.type == "jp2c" } ?: return null
        return j2k(codestream.bodyStart)
    }

    /** A bare codestream: the SIZ marker's reference grid less its offset. */
    private fun j2k(start: Int): ImageHeader? {
        if (!startsWith(start, 0xFF, 0x4F, 0xFF, 0x51)) return null
        val siz = start + 4
        // Lsiz and Rsiz, then Xsiz, Ysiz, XOsiz and YOsiz.
        val width = be32(siz + 4) - be32(siz + 12)
        val height = be32(siz + 8) - be32(siz + 16)
        return ImageHeader(ImageHeader.Format.JPEG2000, width, height)
    }

    // PSD

    private fun psd(): ImageHeader? {
        val version = be16(4)
        if (version != 1 && version != 2) return null
        return ImageHeader(ImageHeader.Format.PSD, be32(18), be32(14))
    }

    // ICO and CUR

    /**
     * The first image in the directory. A dimension byte of zero means 256;
     * an entry stored as a PNG is sized by that PNG's own header, which is
     * what a decoder reads.
     */
    private fun ico(): ImageHeader? {
        val count = le16(4)
        if (count == 0) return null
        val entry = 6
        var width = u8(entry).toLong().let { if (it == 0L) 256 else it }
        var height = u8(entry + 1).toLong().let { if (it == 0L) 256 else it }
        val offset = le32(entry + 12)
        if (offset < size && startsWith(offset.toInt(), 0x89, 0x50, 0x4E, 0x47)) {
            val embedded = Bytes(data.copyOfRange(offset.toInt(), size)).png()
            if (embedded != null) {
                width = embedded.pixelWidth
                height = embedded.pixelHeight
            }
        }
        return ImageHeader(ImageHeader.Format.ICO, width, height)
    }

    companion object {
        /** The ISO base media brands ImageIO opens as HEIF or AVIF. */
        val heifBrands = setOf(
            "heic", "heix", "heim", "heis", "hevc", "hevx", "hevm", "hevs", "mif1", "msf1", "avif", "avis", "avio",
        )
    }
}

/** Just enough of a TIFF reader for IFD0's width, height and orientation. */
private class TiffReader(val bytes: Bytes, val base: Int, val littleEndian: Boolean, val end: Int) {
    private fun u16(at: Int): Int {
        if (at + 2 > end) throw IndexOutOfBoundsException()
        return if (littleEndian) bytes.le16(at) else bytes.be16(at)
    }

    private fun u32(at: Int): Long {
        if (at + 4 > end) throw IndexOutOfBoundsException()
        return if (littleEndian) bytes.le32(at) else bytes.be32(at)
    }

    /** Tag to its first value, for the SHORT and LONG tags only. */
    fun firstIfd(): Map<Int, Long> {
        val offset = u32(base + 4)
        if (offset > Int.MAX_VALUE - base) throw IndexOutOfBoundsException()
        val ifd = base + offset.toInt()
        val count = u16(ifd)
        val tags = HashMap<Int, Long>()
        for (index in 0 until count) {
            val entry = ifd + 2 + index * 12
            val tag = u16(entry)
            val value = when (u16(entry + 2)) {
                3 -> u16(entry + 8).toLong()
                4 -> u32(entry + 8)
                else -> continue
            }
            tags.putIfAbsent(tag, value)
        }
        return tags
    }
}
