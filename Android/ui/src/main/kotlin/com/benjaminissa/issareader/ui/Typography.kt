package com.benjaminissa.issareader.ui

import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.util.concurrent.ConcurrentHashMap

/**
 * Type ramp from the design canvas.
 *
 * Newsreader (a serif) carries reading and display; Public Sans carries the
 * interface. Both ship in the app rather than being fetched, so the reader
 * renders identically offline and on first launch. Sizes are in `sp`, so they
 * follow the system's font scale as the Swift ramp follows Dynamic Type.
 *
 * Newsreader is set at its optical size: Apple's text engine applies a variable
 * font's `opsz` axis to match the point size automatically, Android does not,
 * and without it a 34-point title is drawn with the text-size cut.
 */
object Typography {
    const val SERIF_FAMILY = "Newsreader"
    const val SANS_FAMILY = "Public Sans"

    private val serifFamilies = ConcurrentHashMap<Float, FontFamily>()
    private val sansFamily: FontFamily by lazy {
        IssaFonts.variableFamily(R.font.publicsans, R.font.publicsans_italic, opticalSize = null)
    }

    fun serif(size: Float, weight: FontWeight = FontWeight.Normal): TextStyle = TextStyle(
        fontFamily = serifFamilies.getOrPut(size) {
            IssaFonts.variableFamily(R.font.newsreader, R.font.newsreader_italic, opticalSize = size.coerceIn(6f, 72f))
        },
        fontWeight = weight,
        fontSize = size.sp,
    )

    fun sans(size: Float, weight: FontWeight = FontWeight.Normal): TextStyle =
        TextStyle(fontFamily = sansFamily, fontWeight = weight, fontSize = size.sp)

    // Display / reading
    val displayLarge: TextStyle get() = serif(34f, FontWeight.Medium)
    val display: TextStyle get() = serif(28f, FontWeight.Medium)
    val title: TextStyle get() = serif(22f, FontWeight.Medium)
    val bookTitle: TextStyle get() = serif(17f, FontWeight.Medium)

    // Interface
    val headline: TextStyle get() = sans(17f, FontWeight.SemiBold)
    val body: TextStyle get() = sans(15f)
    val callout: TextStyle get() = sans(14f)
    val subhead: TextStyle get() = sans(13f)
    val footnote: TextStyle get() = sans(12f)
    val caption: TextStyle get() = sans(11f)

    /**
     * Letter-spaced uppercase section label, used throughout the canvas. Upper
     * case is applied to the string by [overline] callers (`text.uppercase()`),
     * as SwiftUI's `textCase` does to the view.
     */
    val overline: TextStyle get() = sans(11f, FontWeight.SemiBold).copy(letterSpacing = Metrics.OVERLINE_TRACKING.sp)

    /** The unscaled ramp, so a test can walk the real table rather than a copy of it. */
    val rampSizes: List<Pair<String, Float>> = listOf(
        "displayLarge" to 34f, "display" to 28f, "title" to 22f, "bookTitle" to 17f,
        "headline" to 17f, "body" to 15f, "callout" to 14f, "subhead" to 13f,
        "footnote" to 12f, "caption" to 11f, "overline" to 11f,
    )
}

/**
 * Where the iPhone draws in the system font, SF Pro, Android draws Roboto at
 * the same sizes and weights, so navigation titles, list rows, menus and tab
 * labels keep the iPhone's proportions. The names are Apple's text styles.
 */
object SystemText {
    private val roboto = FontFamily.Default

    private fun style(size: Float, weight: FontWeight = FontWeight.Normal, lineHeight: Float? = null) =
        TextStyle(fontFamily = roboto, fontWeight = weight, fontSize = size.sp, lineHeight = lineHeight?.sp ?: TextStyle.Default.lineHeight)

    val largeTitle = style(34f, FontWeight.Bold, 41f)
    val title1 = style(28f, FontWeight.Normal, 34f)
    val title2 = style(22f, FontWeight.Normal, 28f)
    val title3 = style(20f, FontWeight.Normal, 25f)
    /** An inline navigation title. */
    val navigationTitle = style(17f, FontWeight.SemiBold, 22f)
    val headline = style(17f, FontWeight.SemiBold, 22f)
    val body = style(17f, FontWeight.Normal, 22f)
    val callout = style(16f, FontWeight.Normal, 21f)
    val subheadline = style(15f, FontWeight.Normal, 20f)
    val footnote = style(13f, FontWeight.Normal, 18f)
    val caption1 = style(12f, FontWeight.Normal, 16f)
    val caption2 = style(11f, FontWeight.Normal, 13f)
    /** The tab bar's labels. */
    val tabLabel = style(12f, FontWeight.Medium, 16f)
    val link = body.copy(textDecoration = TextDecoration.Underline)
}

/** Spacing and radius scale, matching the canvas's rhythm. */
object Metrics {
    val spacing4: Dp = 4.dp
    val spacing8: Dp = 8.dp
    val spacing12: Dp = 12.dp
    val spacing16: Dp = 16.dp
    val spacing24: Dp = 24.dp
    val spacing32: Dp = 32.dp
    val spacing48: Dp = 48.dp

    val radiusSmall: Dp = 6.dp
    val radiusMedium: Dp = 11.dp
    val radiusLarge: Dp = 14.dp

    /** The overline's letter-spacing. */
    const val OVERLINE_TRACKING: Float = 1.6f

    /**
     * The screen's own horizontal margin: one token rather than the same
     * literal retyped on every screen, which is how the header, the grid and
     * the navigation title drifted apart on the iPhone.
     */
    val screenMargin: Dp = 16.dp

    /** Portrait ebook covers; the canvas draws them at a 2:3 ratio. */
    const val COVER_ASPECT: Float = 2f / 3f
}
