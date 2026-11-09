package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.ui.graphics.Color
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.render.Rgba
import com.benjaminissa.issareader.ui.hex

/**
 * The colour of each highlight tint: the design canvas's accents, as the
 * Swift client's `ReaderPalette` states them. Fixed values rather than palette
 * tokens, because a highlight is drawn on the page and the page's colour is
 * the reader's choice, not the system's.
 */
object ReaderPalette {
    fun hex(tint: Annotation.Tint): Int = when (tint) {
        Annotation.Tint.TANGERINE -> 0xE2853A
        Annotation.Tint.MOSS -> 0x7C8A5A
        Annotation.Tint.SLATE -> 0x2F3A3F
        Annotation.Tint.ROSE -> 0xC46A6A
        Annotation.Tint.PLUM -> 0x8A6AA8
    }

    fun color(tint: Annotation.Tint): Color = hex(hex(tint))

    /** A stored highlight as the page fills it: the tint at 30 %, under the glyphs. */
    fun pageFill(tint: Annotation.Tint): Rgba = Rgba.hex(hex(tint), 0.30)
}
