package com.benjaminissa.issareader.ui

import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.core.model.asProgression

/**
 * The canvas's uppercase, letter-spaced section label (`overlineStyle()`).
 * Upper-cased here, as SwiftUI's `textCase(.uppercase)` does.
 */
@Composable
fun Overline(text: String, modifier: Modifier = Modifier, color: Color = Palette.inkTertiary) {
    Text(text.uppercase(), modifier = modifier, style = Typography.overline, color = color, maxLines = 1)
}

/** A rail's heading: the overline, and "See all" in the accent when there is more. */
@Composable
fun RailHeader(title: String, modifier: Modifier = Modifier, trailing: String? = null, onSeeAll: (() -> Unit)? = null) {
    Row(
        modifier.fillMaxWidth().padding(horizontal = Metrics.screenMargin),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Overline(title, Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = Typography.caption, color = Palette.inkTertiary)
        if (onSeeAll != null) {
            Text(
                "See all",
                style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = Palette.tangerine,
                modifier = Modifier.padding(start = Metrics.spacing8).clickable(role = Role.Button, onClick = onSeeAll),
            )
        }
    }
}

/**
 * A thin progress bar: the accent over a faint ink track, never narrower than
 * two points so a started book visibly is started. NaN is no progress, not a
 * full bar.
 */
@Composable
fun ProgressBar(value: Double, modifier: Modifier = Modifier, thickness: Dp = 3.dp, track: Color = Palette.ink.copy(alpha = 0.25f)) {
    Layout(
        modifier = modifier.height(thickness),
        content = {
            Box(Modifier.clip(CircleShape).background(track))
            Box(Modifier.clip(CircleShape).background(Palette.tangerine))
        },
    ) { measurables, constraints ->
        val width = constraints.maxWidth
        val height = thickness.roundToPx()
        val fill = maxOf(2.dp.roundToPx(), (width * (value.asProgression ?: 0.0)).toInt()).coerceAtMost(width)
        val trackPlaceable = measurables[0].measure(androidx.compose.ui.unit.Constraints.fixed(width, height))
        val fillPlaceable = measurables[1].measure(androidx.compose.ui.unit.Constraints.fixed(fill, height))
        layout(width, height) {
            trackPlaceable.place(0, 0)
            fillPlaceable.place(0, 0)
        }
    }
}

/**
 * An empty or failed state, drawn from the palette: a quiet symbol, a title,
 * a sentence, and an action when there is one to take.
 */
@Composable
fun PalettePlaceholder(
    symbol: Int,
    title: String,
    message: String,
    modifier: Modifier = Modifier,
    actionTitle: String? = null,
    action: (() -> Unit)? = null,
) {
    Column(
        modifier.fillMaxWidth().padding(Metrics.spacing32),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing12),
    ) {
        Icon(painterResource(symbol), contentDescription = null, tint = Palette.inkQuaternary, modifier = Modifier.size(40.dp))
        Text(title, style = Typography.headline, color = Palette.ink, textAlign = TextAlign.Center)
        Text(message, style = Typography.footnote, color = Palette.inkTertiary, textAlign = TextAlign.Center)
        if (actionTitle != null && action != null) {
            TextButton(onClick = action) {
                Text(actionTitle, style = Typography.callout.copy(fontWeight = FontWeight.SemiBold), color = Palette.tangerinePressed)
            }
        }
    }
}

/** The small "BETA" capsule beside anything the Ask feature titles. */
@Composable
fun BetaPill(modifier: Modifier = Modifier) {
    Text(
        "BETA",
        style = Typography.overline,
        color = Palette.tangerine,
        modifier = modifier
            .clip(CircleShape)
            .background(Palette.tangerine.copy(alpha = 0.15f))
            .padding(horizontal = Metrics.spacing8, vertical = Metrics.spacing4),
    )
}

/**
 * The screen's one primary action: full width, the accent fill darkening
 * while it is held, white label, a spinner in place of the label's icon while
 * it works.
 */
@Composable
fun PrimaryButton(
    title: String,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    working: Boolean = false,
    trailingIcon: Int? = null,
) {
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val fill by animateColorAsState(
        when {
            pressed -> Palette.tangerinePressed
            else -> Palette.tangerine
        },
        animationSpec = tween(120),
        label = "pressed",
    )
    Row(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Metrics.radiusMedium))
            .background(if (enabled) fill else fill.copy(alpha = 0.5f))
            .clickable(interactionSource = interaction, indication = null, enabled = enabled && !working, role = Role.Button, onClick = onClick)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8, Alignment.CenterHorizontally),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (working) CircularProgressIndicator(color = Color.White, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Text(title, style = Typography.headline, color = Color.White)
        if (!working && trailingIcon != null) Icon(painterResource(trailingIcon), contentDescription = null, tint = Color.White, modifier = Modifier.size(18.dp))
    }
}

/** The round back button the iPhone's navigation bar floats over content, in Material's tonal style. */
@Composable
fun BackButton(onClick: () -> Unit, modifier: Modifier = Modifier) {
    FilledTonalIconButton(
        onClick = onClick,
        modifier = modifier.size(44.dp),
        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Palette.surface, contentColor = Palette.ink),
    ) {
        Icon(painterResource(Symbols.chevronLeft), contentDescription = "Back", modifier = Modifier.size(26.dp))
    }
}

/**
 * A screen's title bar: the iPhone's large title that collapses into an inline
 * one as the content scrolls, on paper, with an optional back button and
 * trailing actions. Material's large top app bar, in the system face at the
 * iPhone's sizes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LargeTitleBar(
    title: String,
    scrollBehavior: TopAppBarScrollBehavior,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
) {
    LargeTopAppBar(
        title = { Text(title, maxLines = 1) },
        modifier = modifier,
        navigationIcon = { if (onBack != null) BackButton(onBack, Modifier.padding(start = Metrics.spacing8)) },
        actions = actions,
        collapsedHeight = 56.dp,
        expandedHeight = 112.dp,
        scrollBehavior = scrollBehavior,
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = Palette.paper,
            scrolledContainerColor = Palette.paper,
            titleContentColor = Palette.ink,
            navigationIconContentColor = Palette.ink,
            actionIconContentColor = Palette.ink,
        ),
    )
}

/** An inline title bar, for pushed screens whose title is not a large one. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InlineTitleBar(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    scrollBehavior: TopAppBarScrollBehavior? = null,
) {
    TopAppBar(
        title = { Text(title, style = SystemText.navigationTitle, maxLines = 1) },
        modifier = modifier,
        navigationIcon = { if (onBack != null) BackButton(onBack, Modifier.padding(start = Metrics.spacing8)) },
        actions = actions,
        scrollBehavior = scrollBehavior,
        colors = TopAppBarDefaults.topAppBarColors(
            containerColor = Palette.paper,
            scrolledContainerColor = Palette.paper,
            titleContentColor = Palette.ink,
        ),
    )
}
