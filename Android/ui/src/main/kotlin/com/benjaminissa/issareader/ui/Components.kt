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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CenterAlignedTopAppBar
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.LocalTextStyle
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.TopAppBarScrollBehavior
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
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
        // 44 tall whether or not there is a "See all": the link's tap floor,
        // which sets the rail's rhythm on the iPhone.
        modifier.fillMaxWidth().heightIn(min = 44.dp).padding(horizontal = Metrics.screenMargin),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Overline(title, Modifier.weight(1f))
        if (trailing != null) Text(trailing, style = Typography.caption, color = Palette.inkTertiary)
        if (onSeeAll != null) {
            Text(
                "See all",
                style = Typography.caption.copy(fontWeight = FontWeight.SemiBold),
                color = Palette.tangerinePressed,
                modifier = Modifier
                    .clickable(role = Role.Button, onClickLabel = "See all $title", onClick = onSeeAll)
                    .padding(start = Metrics.spacing8, top = 14.dp, bottom = 14.dp),
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
        // Unbounded when asked for its intrinsic size: a bar has no width of its own.
        val width = if (constraints.hasBoundedWidth) constraints.maxWidth else constraints.minWidth
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
        WrappingText(message, style = Typography.footnote, color = Palette.inkTertiary, textAlign = TextAlign.Center)
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
 *
 * Full tangerine whether or not it can be pressed, as the iPhone's is: its
 * `PressedFillButtonStyle` reads the press and never `isEnabled`, so a button
 * disabled for an empty field looks the same and does nothing. TalkBack still
 * hears it as disabled.
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
            .background(fill)
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
 *
 * Spaced as the iPhone's: Material's 112-high expanded bar left the content
 * 5 lower than the iPhone's, and the gap under the title 8 wider. So the
 * expanded bar is 5 shorter, and the large title — placed from the top of its
 * row, so it does not move with the bar's height — is set 3 lower, where the
 * iPhone's sits: its baseline 24 above what follows.
 *
 * @param navigationIcon what stands where the back button would, for a root
 *   screen that has a button there of its own.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LargeTitleBar(
    title: String,
    scrollBehavior: TopAppBarScrollBehavior,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    navigationIcon: @Composable () -> Unit = { if (onBack != null) BackButton(onBack, Modifier.padding(start = Metrics.spacing8)) },
    actions: @Composable RowScope.() -> Unit = {},
) {
    val expandedStyle = MaterialTheme.typography.headlineMedium
    LargeTopAppBar(
        title = {
            // One lambda draws both titles: the expanded one, in
            // headlineMedium, and the collapsed one in the inline bar, which
            // stays where Material centres it.
            val expanded = LocalTextStyle.current.fontSize == expandedStyle.fontSize
            Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = if (expanded) Modifier.offset(y = LargeTitleDrop) else Modifier)
        },
        modifier = modifier,
        navigationIcon = navigationIcon,
        actions = actions,
        collapsedHeight = 56.dp,
        expandedHeight = LargeTitleExpandedHeight,
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

/** The expanded large-title bar: Material's 112, less the 5 the content sat too low under it. */
private val LargeTitleExpandedHeight: Dp = 107.dp

/** How far below Material's place the large title is set: the 3 lower the iPhone's sits. */
private val LargeTitleDrop: Dp = 3.dp

/**
 * An inline title bar, for pushed screens whose title is not a large one:
 * the title centred between the back button and the actions, as the iPhone's
 * navigation bar sets it — Material's centre-aligned top app bar.
 *
 * @param titleAlpha how much of the title shows: a page whose header says the
 *   same name beneath the bar fades it in once that has scrolled under.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InlineTitleBar(
    title: String,
    modifier: Modifier = Modifier,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    scrollBehavior: TopAppBarScrollBehavior? = null,
    titleAlpha: Float = 1f,
) {
    CenterAlignedTopAppBar(
        title = {
            Text(
                title,
                style = SystemText.navigationTitle,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.alpha(titleAlpha),
            )
        },
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
