package com.benjaminissa.issareader.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** One tab of the bar: its title and symbol. */
data class TabItem(val title: String, val icon: Int)

/**
 * The app's tabs — Library, Reading, Settings — as Material's navigation bar
 * in the palette: the selected tab's symbol and label in the accent on a
 * faint accent pill, the others in ink, on the surface with a hairline above.
 */
@Composable
fun IssaNavigationBar(items: List<TabItem>, selected: Int, onSelect: (Int) -> Unit, modifier: Modifier = Modifier) {
    Column(modifier) {
        HorizontalDivider(thickness = 0.5.dp, color = Palette.border)
        NavigationBar(containerColor = Palette.surface, tonalElevation = 0.dp) {
            items.forEachIndexed { index, item ->
                NavigationBarItem(
                    selected = index == selected,
                    onClick = { onSelect(index) },
                    icon = { Icon(painterResource(item.icon), contentDescription = null, modifier = Modifier.size(26.dp)) },
                    label = { Text(item.title, style = SystemText.tabLabel) },
                    colors = NavigationBarItemDefaults.colors(
                        selectedIconColor = Palette.tangerine,
                        selectedTextColor = Palette.tangerine,
                        indicatorColor = Palette.tangerine.copy(alpha = 0.16f),
                        unselectedIconColor = Palette.ink,
                        unselectedTextColor = Palette.ink,
                    ),
                )
            }
        }
    }
}

/**
 * The circular skip arrow, back or forward, with the interval drawn inside it
 * when [seconds] is given — the player's glyph. Forward is the back arrow
 * mirrored, which is the shape SF Symbols' `goforward` has.
 */
@Composable
fun SkipGlyph(forward: Boolean, size: Dp, modifier: Modifier = Modifier, seconds: Int? = null, numberSize: TextUnit = 8.sp, tint: androidx.compose.ui.graphics.Color = Palette.ink) {
    Box(modifier.size(size), contentAlignment = Alignment.Center) {
        Icon(
            painterResource(Symbols.gobackward),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(size).scale(scaleX = if (forward) -1f else 1f, scaleY = 1f),
        )
        if (seconds != null) {
            Text(
                "$seconds",
                style = Typography.sans(numberSize.value, FontWeight.SemiBold).copy(fontSize = numberSize),
                color = tint,
                modifier = Modifier.padding(top = (size.value * 0.08f).dp),
            )
        }
    }
}

/**
 * The strip that plays above the tabs while a book is playing: a hairline of
 * progress along its top, the square cover, title and chapter, and skip back,
 * play or pause in the accent, skip forward. A tap anywhere else opens the
 * player.
 */
@Composable
fun MiniPlayerBar(
    cover: @Composable () -> Unit,
    title: String,
    chapter: String?,
    isPlaying: Boolean,
    progress: Double,
    onPlayPause: () -> Unit,
    onSkipBack: () -> Unit,
    onSkipForward: () -> Unit,
    onExpand: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier
            .fillMaxWidth()
            .background(Palette.surface)
            .clickable(onClick = onExpand)
            .semantics { contentDescription = "Now playing: $title" },
    ) {
        ProgressBar(progress, Modifier.fillMaxWidth(), thickness = 2.dp, track = Palette.border)
        Row(
            Modifier.padding(horizontal = Metrics.spacing12, vertical = Metrics.spacing8),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12),
        ) {
            Box(Modifier.size(40.dp)) { cover() }
            Column(Modifier.weight(1f)) {
                Text(title, style = Typography.callout, color = Palette.ink, maxLines = 1)
                if (chapter != null) Text(chapter, style = Typography.caption, color = Palette.inkTertiary, maxLines = 1)
            }
            IconButton(onClick = onSkipBack) { SkipGlyph(forward = false, size = 22.dp) }
            IconButton(onClick = onPlayPause) {
                Icon(
                    painterResource(if (isPlaying) Symbols.pauseFill else Symbols.playFill),
                    contentDescription = if (isPlaying) "Pause" else "Play",
                    tint = Palette.tangerine,
                    modifier = Modifier.size(28.dp),
                )
            }
            IconButton(onClick = onSkipForward) { SkipGlyph(forward = true, size = 22.dp) }
        }
    }
}

/**
 * The band the shell keeps for the mini player while nothing plays, so the
 * content does not jump when playback starts (the iPhone's reserved 56 points).
 */
@Composable
fun ReservedPlayerBand(modifier: Modifier = Modifier) {
    Spacer(modifier.fillMaxWidth().height(56.dp))
}
