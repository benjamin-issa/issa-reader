package com.benjaminissa.issareader.render

/**
 * An sRGB colour with its opacity, as four numbers between 0 and 1.
 *
 * The renderer's colours live here, in plain numbers, rather than as a
 * platform colour type: the page themes and highlighters are part of what a
 * page *is*, and their rules are tested on the JVM without a screen. `:ui`
 * turns these into Compose colours and `:render-android` into paint.
 */
data class Rgba(val red: Double, val green: Double, val blue: Double, val alpha: Double = 1.0) {
    /** Packed as Android's `0xAARRGGBB`. */
    val argb: Int
        get() {
            fun channel(value: Double): Int = (value.coerceIn(0.0, 1.0) * 255 + 0.5).toInt()
            return (channel(alpha) shl 24) or (channel(red) shl 16) or (channel(green) shl 8) or channel(blue)
        }

    fun withAlpha(alpha: Double): Rgba = copy(alpha = alpha)

    companion object {
        /** A `0xRRGGBB` literal, which is how the design canvas states every colour. */
        fun hex(hex: Int, alpha: Double = 1.0): Rgba = Rgba(
            red = ((hex shr 16) and 0xFF) / 255.0,
            green = ((hex shr 8) and 0xFF) / 255.0,
            blue = (hex and 0xFF) / 255.0,
            alpha = alpha,
        )
    }
}
