package com.benjaminissa.issareader.render.android

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import com.benjaminissa.issareader.render.ArchivePlate
import com.benjaminissa.issareader.render.ChapterArtwork
import java.nio.ByteBuffer
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Artwork already decoded — the Swift client's `PlatformImage`, which is a
 * `ChapterArtwork` of its own. For illustrations that arrive as bitmaps rather
 * than as a book's bytes, and for tests.
 */
class BitmapArtwork(val bitmap: Bitmap) : ChapterArtwork {
    override val layoutWidth: Double get() = bitmap.width.toDouble()
    override val layoutHeight: Double get() = bitmap.height.toDouble()
}

/**
 * Turning a plate's bytes into pixels, once, when its page is first drawn.
 *
 * Decoded straight to a bounded bitmap — never larger than the original, so an
 * ordinary plate decodes at exactly its own size, and a 15000-pixel one at
 * [ArchivePlate.maxPixelSize] on its longer side. The flat-colour 15000-pixel
 * PNG compresses to a few hundred kilobytes and decodes to most of a gigabyte,
 * which on a phone or a television is the end of the app.
 *
 * `ImageDecoder` first, because it scales while it decodes and turns the
 * picture upright by its EXIF orientation, as ImageIO's thumbnail does for the
 * Swift client (`kCGImageSourceCreateThumbnailWithTransform`); `BitmapFactory`
 * where it cannot, sampling down by powers of two no further than the bound
 * and scaling the rest of the way.
 */
object PlateBitmaps {
    /** The bitmap to draw for some artwork, decoding an [ArchivePlate] the first time only. */
    fun bitmap(artwork: ChapterArtwork): Bitmap? = when (artwork) {
        is BitmapArtwork -> artwork.bitmap
        is ArchivePlate -> artwork.decoded { data, maxPixelSize -> decode(data, maxPixelSize) }
        else -> null
    }

    /** [data] decoded with its longer side at most [maxPixelSize]; `null` when it is no picture this device can decode. */
    fun decode(data: ByteArray, maxPixelSize: Int): Bitmap? {
        val bound = max(maxPixelSize, 1)
        val decoded = try {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(ByteBuffer.wrap(data))) { decoder, info, _ ->
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                val width = info.size.width
                val height = info.size.height
                val longest = max(width, height)
                if (longest > bound) {
                    val scale = bound.toDouble() / longest
                    decoder.setTargetSize(max(1, (width * scale).toInt()), max(1, (height * scale).toInt()))
                }
            }
        } catch (_: Throwable) {
            null
        }
        return decoded ?: decodeWithFactory(data, bound)
    }

    private fun decodeWithFactory(data: ByteArray, bound: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(data, 0, data.size, bounds)
        val longest = max(bounds.outWidth, bounds.outHeight)
        if (longest <= 0) return null
        // The largest power of two that keeps the longer side at or above the
        // bound, so the scaling below only ever shrinks.
        var sample = 1
        while (longest / (sample * 2) >= bound) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val sampled = try {
            BitmapFactory.decodeByteArray(data, 0, data.size, options)
        } catch (_: Throwable) {
            null
        } ?: return null
        val sampledLongest = max(sampled.width, sampled.height)
        if (sampledLongest <= bound) return sampled
        val scale = bound.toDouble() / sampledLongest
        val scaled = Bitmap.createScaledBitmap(
            sampled, max(1, (sampled.width * scale).roundToInt()), max(1, (sampled.height * scale).roundToInt()), true,
        )
        if (scaled !== sampled) sampled.recycle()
        return scaled
    }
}
