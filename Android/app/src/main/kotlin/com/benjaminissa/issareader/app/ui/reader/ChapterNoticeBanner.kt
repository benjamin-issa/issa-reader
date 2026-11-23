package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.dropShadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.shadow.Shadow
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.DpOffset
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.app.ui.settings.observe
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.ui.EInk
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color
import kotlinx.coroutines.delay

/**
 * A chapter that would not open — or narration that would not play — said
 * over the page for a few seconds.
 *
 * A notice rather than the failure screen: the chapter the reader was on is
 * still laid out and still theirs. It goes on its own, and is spoken, because
 * a page that simply did not turn says nothing to anyone who cannot see the
 * banner. Tapped, it goes at once.
 */
@Composable
fun ChapterNoticeBanner(model: ReaderModel, modifier: Modifier = Modifier) {
    val notice = model.chapterNotice
    val theme = model.style.theme
    val view = LocalView.current
    // The last notice shown, so the banner can fade out with its words still in it.
    val shown = remember { arrayOfNulls<ReaderModel.ChapterNotice>(1) }
    if (notice != null) shown[0] = notice
    AnimatedVisibility(
        visible = notice != null,
        modifier = modifier,
        enter = fadeIn(tween(200)),
        exit = fadeOut(tween(200)),
    ) {
        val showing = notice ?: shown[0] ?: return@AnimatedVisibility
        val shape = RoundedCornerShape(Metrics.radiusLarge)
        Text(
            showing.message,
            style = Typography.footnote,
            color = theme.text.color,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .then(if (theme.isEInk) Modifier else Modifier.dropShadow(shape, Shadow(radius = 12.dp, color = Color.Black.copy(alpha = 0.15f), offset = DpOffset(0.dp, 4.dp))))
                // The page's own surface, as the selection menu has it: a
                // system surface goes dark over a light page in dark theme.
                .background(theme.background.color, shape)
                .border(if (theme.isEInk) EInk.outline else 1.dp, theme.ink(0.15).color, shape)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                    model.dismissChapterNotice(showing)
                }
                .padding(horizontal = Metrics.spacing16, vertical = Metrics.spacing12),
        )
    }
    if (notice != null) {
        LaunchedEffect(notice.id) {
            @Suppress("DEPRECATION")
            view.announceForAccessibility(notice.message)
            delay(LIFETIME_MILLIS)
            model.dismissChapterNotice(notice)
        }
    }
}

/** How long a notice stays before it takes itself down. */
private const val LIFETIME_MILLIS = 5_000L

/**
 * Narration the start check stopped ([AudioPlayer.stoppedResponding]), said
 * over the page in the chapter notice's dress. It does not go by itself, as a
 * chapter notice does: the button it explains reads Play for as long as it is
 * true. Pressing play takes it down, and so does a tap.
 *
 * @param player whatever plays this book's narration: the reader's
 *   read-along, or the audiobook engine when it has the book.
 */
@Composable
fun NarrationStoppedBanner(model: ReaderModel, player: AudioPlayer?, modifier: Modifier = Modifier) {
    player.observe()
    val theme = model.style.theme
    val view = LocalView.current
    val stopped = player?.stoppedResponding == true
    AnimatedVisibility(visible = stopped, modifier = modifier, enter = fadeIn(tween(200)), exit = fadeOut(tween(200))) {
        val shape = RoundedCornerShape(Metrics.radiusLarge)
        Text(
            AudioPlayer.STOPPED_RESPONDING_MESSAGE,
            style = Typography.footnote,
            color = theme.text.color,
            textAlign = TextAlign.Center,
            modifier = Modifier
                .then(if (theme.isEInk) Modifier else Modifier.dropShadow(shape, Shadow(radius = 12.dp, color = Color.Black.copy(alpha = 0.15f), offset = DpOffset(0.dp, 4.dp))))
                .background(theme.background.color, shape)
                .border(if (theme.isEInk) EInk.outline else 1.dp, theme.ink(0.15).color, shape)
                .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {
                    player?.dismissStoppedResponding()
                }
                .padding(horizontal = Metrics.spacing16, vertical = Metrics.spacing12),
        )
    }
    if (stopped) {
        LaunchedEffect(player) {
            @Suppress("DEPRECATION")
            view.announceForAccessibility(AudioPlayer.STOPPED_RESPONDING_MESSAGE)
        }
    }
}
