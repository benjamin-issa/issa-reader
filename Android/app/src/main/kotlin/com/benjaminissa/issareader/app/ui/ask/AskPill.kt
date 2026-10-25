package com.benjaminissa.issareader.app.ui.ask

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.ask.AskCoordinator
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.color

/**
 * What the reader's sparkle says about a book's question: nothing asked, an
 * answer being worked out, or an answer waiting.
 */
enum class AskPillState {
    IDLE,
    WORKING,
    READY,
    ;

    /**
     * What a screen reader calls the sparkle — the last place its three
     * states are said in words, now that the glyph says them with a pulse and
     * a dot. A reader who cannot see either still has to be able to tell "you
     * may ask" from "the answer you asked for is waiting".
     */
    val label: String
        get() = when (this) {
            IDLE -> "Ask about this book"
            WORKING -> "Answer being prepared"
            READY -> "Answer ready"
        }
}

/** The sparkle's state for this book: a held question counts as being prepared, which it is. */
fun AskCoordinator.pillState(bookUuid: String): AskPillState {
    val job = job(bookUuid) ?: return AskPillState.IDLE
    return when {
        job.isPending -> AskPillState.WORKING
        job.state.isAnswered -> AskPillState.READY
        else -> AskPillState.IDLE
    }
}

/**
 * Whether the badge over the page should stand in for the bar's sparkle while
 * the reader's chrome is hidden: only when there is something to say. The
 * reader decides the chrome half.
 */
fun AskCoordinator.showsBadge(bookUuid: String): Boolean = isOffered && pillState(bookUuid) != AskPillState.IDLE

/**
 * The bar's sparkle: a bare glyph, so the bar's own ink reaches it exactly as
 * it reaches the glyphs beside it. A tinted capsule with a word in it read as
 * a different class of control — an advertisement in a row of tools. The two
 * states it still has to show are said with the glyph itself: it pulses while
 * an answer is being worked out, and carries a dot in the theme's accent when
 * one is waiting.
 *
 * @param tint the bar's ink.
 * @param dot the reading theme's accent.
 */
@Composable
fun AskSparkle(state: AskPillState, tint: Color, dot: Color, modifier: Modifier = Modifier, size: Dp = 24.dp) {
    Box(modifier.clearAndSetSemantics { contentDescription = state.label }) {
        Icon(
            painterResource(Symbols.sparkles),
            contentDescription = null,
            tint = tint,
            modifier = Modifier.size(size).alpha(pulse(state == AskPillState.WORKING)),
        )
        if (state == AskPillState.READY) {
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .offset(x = 3.dp, y = (-2).dp)
                    .size(6.dp)
                    .background(dot, CircleShape),
            )
        }
    }
}

/**
 * The cue that survives the chrome being hidden.
 *
 * Reading with the bars away is the ordinary case, and it is exactly when a
 * reader is most likely to have closed the sheet and be waiting. Without this
 * the only sign the app is working disappears with the top bar. It stands
 * alone over the page with no bar to belong to, so it keeps the disc and the
 * border that make it a control rather than a mark on the paper.
 */
@Composable
fun AskStatusBadge(theme: ReaderTheme, state: AskPillState, modifier: Modifier = Modifier) {
    val accent = theme.accent.color
    Box(
        modifier
            .size(28.dp)
            .background(theme.background.color.copy(alpha = 0.9f), CircleShape)
            .border(1.dp, accent.copy(alpha = 0.3f), CircleShape)
            .clearAndSetSemantics { contentDescription = if (state == AskPillState.READY) "Answer ready" else "Answer being prepared" },
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            painterResource(Symbols.sparkles),
            contentDescription = null,
            tint = accent,
            modifier = Modifier.size(15.dp).alpha(pulse(state == AskPillState.WORKING)),
        )
    }
}

/**
 * Whether the Ask pieces animate: their pulse and the sheet's sweeping bars.
 * False for a still picture of them — a screenshot waits for the composition to
 * settle, and an animation that repeats for ever never lets it.
 */
val LocalAskMotion = staticCompositionLocalOf { true }

/** The glyph's pulse while an answer is being worked out; fully drawn otherwise. */
@Composable
private fun pulse(active: Boolean): Float {
    if (!active || !LocalAskMotion.current) return 1f
    val transition = rememberInfiniteTransition(label = "ask pulse")
    val alpha = transition.animateFloat(
        initialValue = 1f,
        targetValue = 0.35f,
        animationSpec = infiniteRepeatable(tween(700, easing = FastOutSlowInEasing), RepeatMode.Reverse),
        label = "ask pulse alpha",
    )
    return alpha.value
}
