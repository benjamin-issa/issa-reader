package com.benjaminissa.issareader.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.material3.Typography as MaterialTypography
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
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
 */
@Composable
fun IssaTheme(darkTheme: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val colors = if (darkTheme) IssaColors.Dark else IssaColors.Light
    CompositionLocalProvider(LocalIssaColors provides colors) {
        MaterialTheme(
            colorScheme = colorScheme(colors),
            typography = materialTypography,
            shapes = Shapes(
                extraSmall = RoundedCornerShape(Metrics.radiusSmall),
                small = RoundedCornerShape(Metrics.radiusMedium),
                medium = RoundedCornerShape(Metrics.radiusLarge),
                large = RoundedCornerShape(26.dp),
                extraLarge = RoundedCornerShape(28.dp),
            ),
            content = content,
        )
    }
}

internal fun colorScheme(c: IssaColors): ColorScheme {
    val base = if (c.isDark) darkColorScheme() else lightColorScheme()
    return base.copy(
        primary = c.tangerine,
        onPrimary = Color.White,
        primaryContainer = c.tangerine.copy(alpha = 0.16f),
        onPrimaryContainer = c.ink,
        inversePrimary = c.tangerinePressed,
        secondary = c.moss,
        onSecondary = Color.White,
        secondaryContainer = c.tangerine.copy(alpha = 0.14f),
        onSecondaryContainer = c.ink,
        tertiary = c.slate,
        onTertiary = Color.White,
        background = c.paper,
        onBackground = c.ink,
        surface = c.paper,
        onSurface = c.ink,
        surfaceVariant = c.surfaceRaised,
        onSurfaceVariant = c.inkSecondary,
        surfaceTint = Color.Transparent,
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
        scrim = Color.Black.copy(alpha = 0.32f),
    )
}

private val materialTypography = MaterialTypography(
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
