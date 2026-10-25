package com.benjaminissa.issareader.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import java.text.BreakIterator
import java.util.Locale

/**
 * A book cover, or the design's placeholder when there is no art: a tinted
 * block carrying the author's initial, never an empty grey rectangle.
 *
 * The art is cropped to fill a box that sizes itself from [aspect], so a
 * square jacket in a portrait slot never bleeds into its neighbour; corners
 * at the small radius with a hairline of ink, as on the iPhone. The loading
 * lives with the cover cache in the app; this draws what it is given.
 */
@Composable
fun CoverArt(
    image: ImageBitmap?,
    uuid: String,
    initialSource: String,
    modifier: Modifier = Modifier,
    aspect: Float = Metrics.COVER_ASPECT,
    contentDescription: String? = null,
) {
    val shape = RoundedCornerShape(Metrics.radiusSmall)
    Box(
        modifier
            .aspectRatio(aspect)
            .clip(shape)
            .border(0.5.dp, Palette.ink.copy(alpha = 0.10f), shape),
        contentAlignment = Alignment.Center,
    ) {
        if (image != null) {
            Image(image, contentDescription = contentDescription, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
        } else {
            val tint = CoverPlaceholder.tints()[CoverPlaceholder.tintIndex(uuid)]
            Box(Modifier.fillMaxSize().background(tint.copy(alpha = 0.28f)), contentAlignment = Alignment.Center) {
                Text(
                    CoverPlaceholder.initial(initialSource),
                    style = Typography.serif(34f, FontWeight.Medium),
                    color = Palette.ink.copy(alpha = 0.55f),
                    maxLines = 1,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(2.dp),
                )
            }
        }
    }
}

object CoverPlaceholder {
    /** The six tints, in the Swift client's order. */
    @Composable
    fun tints(): List<Color> = listOf(Palette.tangerine, Palette.moss, Palette.slate, hex(0xC46A6A), hex(0x8A6AA8), Palette.borderStrong)

    /**
     * Which tint a book's placeholder wears: a stable hash of its uuid, the
     * same arithmetic as the Swift client's, so a book without art is the same
     * colour on both — and on every launch, which a seeded hash was not.
     */
    fun tintIndex(uuid: String): Int =
        uuid.encodeToByteArray().fold(0) { acc, byte -> (acc * 31 + (byte.toInt() and 0xFF)) % 4096 } % 6

    /** The first character of the author's name (or the title), upper-cased. */
    fun initial(source: String): String {
        val text = source.trim()
        if (text.isEmpty()) return ""
        val clusters = BreakIterator.getCharacterInstance().apply { setText(text) }
        return text.substring(0, clusters.next()).uppercase(Locale.ROOT)
    }
}
