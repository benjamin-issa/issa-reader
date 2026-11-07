package com.benjaminissa.issareader.ui

import androidx.compose.foundation.LocalIndication
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.LocalRippleConfiguration
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.Typography as MaterialTypography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * The app's theme: the Issa palette, and Material 3 restyled in it.
 *
 * System controls are Material's own — switches, segmented buttons, menus,
 * dialogs, sheets, the navigation bar — drawn in the palette rather than in
 * Material's dynamic colour, so they sit on the same warm paper as everything
 * the app draws itself. Their text is Roboto at the iPhone's system sizes
 * ([SystemText]).
 *
 * @param eink E-Ink mode, which outranks [darkTheme]: a panel has no dark
 *   appearance worth having, and the mode's palette is one pair of colours.
 */
@Composable
fun IssaTheme(darkTheme: Boolean = isSystemInDarkTheme(), eink: Boolean = false, content: @Composable () -> Unit) {
    val colors = if (eink) IssaColors.EInk else if (darkTheme) IssaColors.Dark else IssaColors.Light
    Typography.smallest = if (eink) EInk.SMALLEST_TEXT else 0f
    CompositionLocalProvider(LocalIssaColors provides colors) {
        MaterialTheme(
            colorScheme = colorScheme(colors),
            typography = remember(eink) { materialTypography() },
            shapes = if (eink) einkShapes else issaShapes,
        ) {
            // The same tree in both modes, because saved state is found by its
            // place in the tree: the restart that follows the switch has to
            // bring back the screen it was on.
            CompositionLocalProvider(values = if (eink) einkLocals() else emptyArray(), content = content)
        }
    }
}

/** No ripple on anything: Material's own read the configuration, and what clicks read is the press. */
@OptIn(ExperimentalMaterial3Api::class)
private fun einkLocals() = arrayOf(LocalRippleConfiguration provides null, LocalIndication provides EInkIndication)

private val issaShapes = Shapes(
    extraSmall = RoundedCornerShape(Metrics.radiusSmall),
    small = RoundedCornerShape(Metrics.radiusMedium),
    medium = RoundedCornerShape(Metrics.radiusLarge),
    large = RoundedCornerShape(26.dp),
    extraLarge = RoundedCornerShape(28.dp),
)

private val einkShapes = RoundedCornerShape(EInk.radius).let { Shapes(it, it, it, it, it) }

internal fun colorScheme(c: IssaColors): ColorScheme {
    val base = if (c.isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = c.tangerine,
        onPrimary = Color.White,
        primaryContainer = if (c.isEInk) c.paper else c.tangerine.copy(alpha = 0.16f),
        onPrimaryContainer = c.ink,
        inversePrimary = c.tangerinePressed,
        secondary = c.moss,
        onSecondary = Color.White,
        secondaryContainer = if (c.isEInk) c.paper else c.tangerine.copy(alpha = 0.14f),
        onSecondaryContainer = c.ink,
        tertiary = c.slate,
        onTertiary = Color.White,
        background = c.paper,
        onBackground = c.ink,
        surface = c.paper,
        onSurface = c.ink,
        surfaceVariant = c.surfaceRaised,
        onSurfaceVariant = c.inkSecondary,
        // Paper in E-Ink mode: Material takes this at an alpha for a raised
        // surface, and transparent at an alpha is black, so a grey sheet.
        surfaceTint = if (c.isEInk) c.paper else Color.Transparent,
        surfaceBright = c.surface,
        surfaceDim = c.paper,
        surfaceContainerLowest = c.surface,
        surfaceContainerLow = c.surface,
        surfaceContainer = c.surface,
        surfaceContainerHigh = c.surface,
        surfaceContainerHighest = c.surfaceRaised,
        inverseSurface = c.ink,
        inverseOnSurface = c.paper,
        outline = c.borderStrong,
        outlineVariant = c.border,
        error = c.alert,
        onError = Color.White,
        scrim = if (c.isEInk) Color.Transparent else Color.Black.copy(alpha = 0.32f),
    )
}

/** Built here rather than held, so that it comes out at the theme's [Typography.smallest]. */
private fun materialTypography() = MaterialTypography(
    displayLarge = SystemText.largeTitle,
    displayMedium = SystemText.largeTitle,
    displaySmall = SystemText.title1,
    headlineLarge = SystemText.title1,
    // Material's large top app bar sets its expanded title in headlineMedium:
    // the iPhone's large title.
    headlineMedium = SystemText.largeTitle,
    headlineSmall = SystemText.title3,
    titleLarge = SystemText.navigationTitle,
    titleMedium = SystemText.headline,
    titleSmall = SystemText.subheadline,
    bodyLarge = SystemText.body,
    bodyMedium = SystemText.subheadline,
    bodySmall = SystemText.footnote,
    labelLarge = SystemText.subheadline,
    labelMedium = SystemText.tabLabel,
    labelSmall = SystemText.caption2,
)
