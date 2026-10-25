package com.benjaminissa.issareader.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import com.benjaminissa.issareader.render.Rgba

/**
 * The Issa Reader palette, taken from the design canvas.
 *
 * Warm paper rather than stock system grey, so these are literal values rather
 * than Material's dynamic colour — and every one of them is a light/dark pair.
 * The app's chrome follows the system's dark theme; the reading themes
 * (`ReaderTheme`) deliberately do not.
 */
@Immutable
data class IssaColors(
    // Ground and surfaces
    val paper: Color,
    val surface: Color,
    val surfaceRaised: Color,
    val border: Color,
    val borderStrong: Color,
    // Ink
    val ink: Color,
    val inkSecondary: Color,
    val inkTertiary: Color,
    val inkQuaternary: Color,
    // Accents, lifted in the dark so they keep their contrast against a near
    // black ground rather than sinking into it.
    val tangerine: Color,
    val tangerinePressed: Color,
    val moss: Color,
    val slate: Color,
    /** Something went wrong, or is missing. */
    val alert: Color,
    val isDark: Boolean,
) {
    companion object {
        val Light = IssaColors(
            paper = hex(0xEFE8DC), surface = hex(0xFFFDF8), surfaceRaised = hex(0xF6F1E9),
            border = hex(0xE7DED0), borderStrong = hex(0xD8CCB8),
            ink = hex(0x221F1A), inkSecondary = hex(0x5F584C), inkTertiary = hex(0x8A8172), inkQuaternary = hex(0xA89E8D),
            tangerine = hex(0xE2853A), tangerinePressed = hex(0xC26A25), moss = hex(0x7C8A5A), slate = hex(0x2F3A3F),
            alert = hex(0x7A2F2A), isDark = false,
        )
        val Dark = IssaColors(
            paper = hex(0x17150F), surface = hex(0x1C1915), surfaceRaised = hex(0x26302F),
            border = hex(0x3A342A), borderStrong = hex(0x4A4133),
            ink = hex(0xF4EFE3), inkSecondary = hex(0xC9BEAC), inkTertiary = hex(0x9A9080), inkQuaternary = hex(0x7A7263),
            tangerine = hex(0xEE9B57), tangerinePressed = hex(0xF0AC74), moss = hex(0x9DAE74), slate = hex(0x8FA6B0),
            alert = hex(0xE08C84), isDark = true,
        )
    }
}

val LocalIssaColors = staticCompositionLocalOf { IssaColors.Light }

/**
 * The palette tokens, resolved for the composition's appearance — written
 * `Palette.ink` at every call site, as the Swift views write it.
 */
object Palette {
    val paper: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.paper
    val surface: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.surface
    val surfaceRaised: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.surfaceRaised
    val border: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.border
    val borderStrong: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.borderStrong
    val ink: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.ink
    val inkSecondary: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.inkSecondary
    val inkTertiary: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.inkTertiary
    val inkQuaternary: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.inkQuaternary
    val tangerine: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.tangerine
    val tangerinePressed: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.tangerinePressed
    val moss: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.moss
    val slate: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.slate
    val alert: Color @Composable @ReadOnlyComposable get() = LocalIssaColors.current.alert
    val isDark: Boolean @Composable @ReadOnlyComposable get() = LocalIssaColors.current.isDark
}

/** A `0xRRGGBB` literal, which is how the design canvas expresses every colour. */
fun hex(rgb: Int, alpha: Float = 1f): Color = Color(0xFF000000.toInt() or rgb).copy(alpha = alpha)

/** A renderer colour (`ReaderTheme`, highlighters) as a Compose colour. */
val Rgba.color: Color get() = Color(red.toFloat(), green.toFloat(), blue.toFloat(), alpha.toFloat())

/**
 * A `"#RRGGBB"` string, which is how the server states a source's colour.
 *
 * Fails rather than defaulting to black: a colour that could not be read is
 * better replaced by a palette token at the call site than drawn wrong.
 */
fun colorFromHexString(string: String?): Color? {
    var text = string?.trim()?.takeIf { it.isNotEmpty() } ?: return null
    if (text.startsWith("#")) text = text.drop(1)
    if (text.length != 6) return null
    val value = text.toIntOrNull(16) ?: return null
    return hex(value)
}
