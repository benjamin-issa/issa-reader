package com.benjaminissa.issareader.app.ui.shell

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.layout.layout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.ui.InlineTitleBar
import com.benjaminissa.issareader.ui.LargeTitleBar
import com.benjaminissa.issareader.ui.LocalPlayerBand
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import kotlinx.coroutines.launch

/**
 * A tab's first screen: the iPhone's large title, collapsing into the inline
 * one as the content scrolls, over the paper.
 *
 * The window's top inset is the title bar's; the bottom is the shell's, which
 * has set the content above the tabs. The mini player's band is not taken
 * out of it: the content runs beneath the band, and a scrolling screen pads
 * its end by [LocalPlayerBand] so its last item can clear it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LargeTitleScreen(title: String, modifier: Modifier = Modifier, content: @Composable (PaddingValues) -> Unit) {
    val behavior = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    Scaffold(
        modifier = modifier.nestedScroll(behavior.nestedScrollConnection),
        topBar = { LargeTitleBar(title, behavior) },
        containerColor = Palette.paper,
        contentWindowInsets = WindowInsets(0),
        content = content,
    )
}

/**
 * A page pushed on a tab: the inline title and the round back button.
 *
 * @param topBar a bar of the screen's own, for a page whose title does more
 *   than sit there (the tag page's, which fades in).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PushedScreen(
    title: String,
    modifier: Modifier = Modifier,
    topBar: (@Composable () -> Unit)? = null,
    content: @Composable (PaddingValues) -> Unit,
) {
    val navigator = LocalTabNavigator.current
    Scaffold(
        modifier = modifier,
        topBar = topBar ?: { InlineTitleBar(title, onBack = { navigator.back() }) },
        containerColor = Palette.paper,
        contentWindowInsets = WindowInsets(0),
        content = content,
    )
}

/**
 * Pull to refresh, in Material's indicator drawn in the palette: Swift's
 * `.refreshable`. The indicator stays up until [onRefresh] returns.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Refreshable(onRefresh: suspend () -> Unit, modifier: Modifier = Modifier, content: @Composable BoxScope.() -> Unit) {
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val state = rememberPullToRefreshState()
    PullToRefreshBox(
        isRefreshing = refreshing,
        onRefresh = {
            refreshing = true
            scope.launch {
                try {
                    onRefresh()
                } finally {
                    refreshing = false
                }
            }
        },
        modifier = modifier,
        state = state,
        indicator = {
            PullToRefreshDefaults.Indicator(
                state = state,
                isRefreshing = refreshing,
                modifier = Modifier.align(Alignment.TopCenter),
                containerColor = Palette.surface,
                color = Palette.tangerine,
            )
        },
        content = content,
    )
}

/**
 * Lets a rail reach the screen's edges from inside a list padded by
 * [margin], as Swift's negative padding does: the rail keeps the margin as
 * its own content inset, so a shelf that continues off screen does not look
 * cut off.
 */
fun Modifier.bleed(margin: Dp = Metrics.screenMargin): Modifier = layout { measurable, constraints ->
    val inset = margin.roundToPx()
    val width = constraints.maxWidth + inset * 2
    val placeable = measurable.measure(constraints.copy(minWidth = width, maxWidth = width))
    layout(constraints.maxWidth, placeable.height) { placeable.place(-inset, 0) }
}

/** The system spinner in the accent, centred above the mini player's band: Swift's bare `ProgressView()` over a loading screen. */
@Composable
fun LoadingOverlay(modifier: Modifier = Modifier) {
    Box(modifier.fillMaxSize().padding(bottom = LocalPlayerBand.current), contentAlignment = Alignment.Center) {
        CircularProgressIndicator(color = Palette.inkTertiary, strokeWidth = 2.5.dp, modifier = Modifier.size(28.dp).padding(2.dp))
    }
}
