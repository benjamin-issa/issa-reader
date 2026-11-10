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
     * Never wider than the column it lands in, and never taller than the page.
     *
     * The column: one narrower than the one the chapter was parsed for — a
     * rotation, a split screen — would otherwise leave the plate overhanging
     * its right edge. The page: [displaySize] bounded the height for the page
     * the chapter was parsed for, but a rotation re-lays the chapter out
     * without parsing it again, and a plate fitted to a tall page, turned
     * onto a wide one, was left taller than the page, its lower part
     * unreachable by turning pages. So both bounds are applied here as well,
     * scaling by whichever is tighter and keeping the aspect ratio. Never up.
     */
    fun bounds(displayWidth: Double, displayHeight: Double, availableWidth: Double, availableHeight: Double): Size {
        var scale = 1.0
        if (availableWidth > 0 && displayWidth > availableWidth) scale = availableWidth / displayWidth
        if (availableHeight > 0 && displayHeight * scale > availableHeight) scale = availableHeight / displayHeight
        return if (scale == 1.0) Size(displayWidth, displayHeight) else Size(displayWidth * scale, displayHeight * scale)
    }
}
