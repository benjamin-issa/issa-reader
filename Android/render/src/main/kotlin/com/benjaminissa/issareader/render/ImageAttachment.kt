package com.benjaminissa.issareader.render

/**
 * How big an illustration is drawn: the arithmetic of the Swift client's
 * `ImageAttachment`, which on Android is a `ReplacementSpan` in
 * `:render-android`.
 *
 * Two bounds, applied at two moments. The parser scales a plate to fit the
 * column and the page it was parsed for ([displaySize]); layout then keeps it
 * inside whatever column it actually lands in ([bounds]), because a plate
 * that overflows the measure is clipped rather than scaled by the layout
 * engine.
 */
object ImageAttachment {
    /** A width and a height, in points. */
    data class Size(val width: Double, val height: Double)

    /**
     * The size a plate takes in the flow, given its own and the room there is.
     *
     * Both bounds, never up: an upscaled 60px decoration looks worse than a
     * small one, and a plate taller than the page cannot be paged through.
     * Without the page bound a tall plate was scaled to the column and left
     * taller than the page: pagination gave that oversized line a page of its
     * own whose content extent exceeded the canvas, the draw clipped to the
     * canvas, and the rest of the picture was painted outside it — unreachable
     * on every page, with the page turn skipping straight past. A full-page
     * cover or map showed only its top.
     */
    fun displaySize(width: Double, height: Double, maxWidth: Double, maxHeight: Double): Size {
        val scale = minOf(1.0, minOf(maxWidth / width, maxHeight / height))
        return Size(width * scale, height * scale)
    }

    /**
     * Never wider than the column it lands in. A column narrower than the one
     * the chapter was parsed for — a rotation, a split screen — would
     * otherwise leave the plate overhanging its right edge.
     */
    fun bounds(displayWidth: Double, displayHeight: Double, availableWidth: Double): Size {
        if (!(availableWidth > 0) || displayWidth <= availableWidth) return Size(displayWidth, displayHeight)
        val scale = availableWidth / displayWidth
        return Size(availableWidth, displayHeight * scale)
    }
}
