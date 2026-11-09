package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.epub.EpubArchive

/**
 * An illustration as the parser needs it: a size to lay it out by now, and
 * artwork to draw only once the page it is on is drawn.
 *
 * [ArchivePlate] is the one the reader, the in-book search and the Ask index
 * use: it reads its size from the image's header and decodes when drawn, so a
 * parse that only wants the text — every search, every index build — decodes
 * nothing. Decoding belongs to `:render-android`, which turns a plate's bytes
 * into a bitmap; this module never draws.
 */
interface ChapterArtwork {
    /**
     * What the parser scales the plate by: the size `UIImage(data:)` reports
     * on the iPhone — pixels, turned upright. See [ImageHeader.layoutWidth].
     */
    val layoutWidth: Double
    val layoutHeight: Double
}

/**
 * A chapter's artwork, keyed by archive path: each plate's size at once, its
 * pixels only when it is drawn.
 *
 * A chapter asks once per plate, and the cache lives as long as the chapter
 * does, so reflowing on a font change costs no re-reading.
 *
 * It lives in `:render` rather than in the app because the Ask index parses
 * chapters with it too, and its offsets are only right because it does: every
 * plate contributes an object-replacement character and a line break to the
 * rendered string, so a parse without the images computes offsets that drift
 * ahead of the laid-out chapter's — far enough on an illustrated book to place
 * a retrieved passage in the wrong place, and to let the spoiler boundary cut
 * in the wrong place with it.
 *
 * Neither the search nor the Ask index ever draws, so neither ever decodes:
 * a parse reads each plate's header and nothing more. See [ArchivePlate].
 *
 * Not thread-safe: one chapter's source is used by one parse at a time, as
 * the Swift one is used on one actor.
 */
class ArchiveImageSource(
    private val archive: EpubArchive,
    private val maxPixelSize: Int = DEFAULT_MAX_PIXEL_SIZE,
) {
    private val plates = HashMap<String, ArchivePlate?>()
    private val decodes = ArchivePlate.DecodeCounter()

    /**
     * The plate at an archive path, sized but not decoded; `null` when the
     * entry is missing or is no image at all.
     */
    fun image(href: String): ArchivePlate? {
        if (plates.containsKey(href)) return plates[href]
        val data = try {
            archive.read(href)
        } catch (_: Exception) {
            null
        }
        val result = data?.let { ArchivePlate.of(it, maxPixelSize, decodes) }
        plates[href] = result
        return result
    }

    /**
     * How many bitmaps this source's plates have decoded. For the tests that
     * hold the parse to reading headers only.
     */
    val decodeCount: Int get() = decodes.count

    companion object {
        /**
         * The longest side, in pixels, a plate is decoded at.
         *
         * Far more than any column draws — a full-width plate on the widest
         * tablet at 3x is under 4000 — and far less than the flat-colour
         * 15000-pixel PNG that compresses to a few hundred kilobytes and
         * decodes to most of a gigabyte, which on a phone or a television is
         * the end of the app.
         */
        const val DEFAULT_MAX_PIXEL_SIZE = 4096
    }
}

/**
 * One illustration: its size from the image's header, its bitmap decoded the
 * first time the page it is on is drawn.
 *
 * Decoded straight to a bounded bitmap — never larger than the original, so an
 * ordinary plate decodes at exactly its own size, and a 15000-pixel one at
 * [ArchiveImageSource.DEFAULT_MAX_PIXEL_SIZE]. Kept once decoded, because
 * every narrated sentence and page turn redraws the page.
 *
 * Holds the image's own bytes rather than the archive: a plate is drawn on the
 * main thread while a search may be reading the same book's archive elsewhere.
 *
 * The decode itself is `:render-android`'s, handed in to [decoded]; this keeps
 * the rule that it happens once, and counts it.
 */
class ArchivePlate private constructor(
    val header: ImageHeader,
    /** The image file's bytes, as the book stores them. */
    val data: ByteArray,
    /** The longest side a decode may produce. */
    val maxPixelSize: Int,
    private val decodes: DecodeCounter,
) : ChapterArtwork {
    /** Counts decodes for one [ArchiveImageSource]. */
    internal class DecodeCounter {
        var count = 0
    }

    override val layoutWidth: Double get() = header.layoutWidth
    override val layoutHeight: Double get() = header.layoutHeight

    private var attempted = false
    private var bitmap: Any? = null

    /**
     * The decoded artwork, decoding it with [decode] the first time it is
     * asked for and never again — a decode that failed is not retried on
     * every redraw either.
     */
    @Synchronized
    fun <T : Any> decoded(decode: (data: ByteArray, maxPixelSize: Int) -> T?): T? {
        if (!attempted) {
            attempted = true
            decodes.count += 1
            bitmap = decode(data, maxPixelSize)
        }
        @Suppress("UNCHECKED_CAST")
        return bitmap as T?
    }

    /** Whether the plate has been decoded yet. For tests. */
    val isDecoded: Boolean @Synchronized get() = attempted

    companion object {
        /**
         * A plate for [data], or `null` when it is no image the header
         * reader can size. There is no second chance through a full decode,
         * as there is on the Mac for an SVG: on the iPhone a format ImageIO
         * cannot size is no plate, and the two clients must agree on which
         * plates exist — see [ImageHeader].
         */
        internal fun of(data: ByteArray, maxPixelSize: Int, decodes: DecodeCounter): ArchivePlate? {
            val header = ImageHeader.read(data) ?: return null
            return ArchivePlate(header, data, maxOf(maxPixelSize, 1), decodes)
        }

        /** A plate for bytes from anywhere, with its own decode count. */
        fun of(data: ByteArray, maxPixelSize: Int = ArchiveImageSource.DEFAULT_MAX_PIXEL_SIZE): ArchivePlate? =
            of(data, maxPixelSize, DecodeCounter())
    }
}

/** An illustration that is only a size: for tests, and for art already in hand. */
data class SizedArtwork(override val layoutWidth: Double, override val layoutHeight: Double) : ChapterArtwork
