package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.render.ReaderTheme
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Symbols
import com.benjaminissa.issareader.ui.Typography
import com.benjaminissa.issareader.ui.color

/** The guide's words: the phone's, which are about taps. */
internal object CoachCopy {
    const val ZONE_HEADLINE = "Tap the page to turn it"
    const val SELECT_TIP = "Press and hold to select text."
    const val READ_ALOUD_TIP = "Double-tap a line to hear it."
    const val PLAYER_TIP = "Tap the waveform, or swipe up, for the player."
    const val DISMISS = "Tap anywhere to begin"
    const val SPOKEN_ZONES = "Reading gestures. Tap the left edge to turn back, the middle to " +
        "show or hide the controls, the right edge to turn forward. " +
        "Press and hold to select text."
    const val SPOKEN_NARRATION = "This book is narrated. Double-tap a line to hear it read aloud. " +
        "The play button's Open player action shows the full player."
}

/**
 * A one-time guide, drawn over the page the first time the reader opens.
 *
 * It names the three tap zones — the left edge turns back, the middle shows
 * and hides the controls, the right edge turns forward — and the press and
 * hold that selects text, none of which a bare page announces. On a narrated
 * book it adds the single line the double-tap gesture needs: that tapping a
 * line twice reads it aloud.
 *
 * Coloured from the reader's *theme*, not the system palette, for the same
 * reason the rest of the reader is: someone reading Paper in dark theme has
 * asked for a light page, and a system-tinted scrim over it would be the one
 * dark rectangle on screen. With animations removed the guide is simply
 * there, with no fade or lift.
 *
 * @param showsZones whether to name the tap zones. False once the guide has
 *   been seen, so a narrated book opened later can still show its tip alone.
 * @param showsNarrationTip whether to add the read-aloud tip.
 */
@Composable
fun ReaderCoachOverlay(
    theme: ReaderTheme,
    showsZones: Boolean,
    showsNarrationTip: Boolean,
    reduceMotion: Boolean,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val shown = remember { Animatable(if (reduceMotion) 1f else 0f) }
    LaunchedEffect(Unit) {
        if (!reduceMotion) shown.animateTo(1f, tween(280, easing = FastOutSlowInEasing))
    }
    val spoken = listOfNotNull(
        CoachCopy.SPOKEN_ZONES.takeIf { showsZones },
        CoachCopy.SPOKEN_NARRATION.takeIf { showsNarrationTip },
    ).joinToString(" ")
    Box(
        modifier
            .fillMaxSize()
            .graphicsLayer {
                alpha = shown.value
                val scale = 0.96f + 0.04f * shown.value
                scaleX = scale
                scaleY = scale
            }
            // A full-bleed catcher over the whole window: a tap anywhere is
            // the only way out, so it must cover the page, both bars and the
            // unsafe edges. The page's own colour dimmed over itself.
            .background(theme.background.withAlpha(if (theme.isDark) 0.80 else 0.84).color)
            // The whole layer takes the tap that dismisses it, so the page
            // beneath does not also turn a page on the way out.
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null, onClick = onDismiss)
            // One element for TalkBack: the guide as a sentence, and a button
            // that dismisses it.
            .clearAndSetSemantics {
                contentDescription = spoken
                role = Role.Button
                onClick(label = "Dismiss") {
                    onDismiss()
                    true
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier.widthIn(max = 420.dp).padding(Metrics.spacing32),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(Metrics.spacing24),
        ) {
            if (showsZones) ZoneGuide(theme)
            if (showsNarrationTip) {
                Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
                    Tip(theme, Symbols.handTap, CoachCopy.READ_ALOUD_TIP)
                    // The strip's own buttons need no explaining; the route to
                    // the full player — the scrubber, the rate, the sleep
                    // timer — does, since one of the two ways there is a swipe.
                    Tip(theme, Symbols.waveform, CoachCopy.PLAYER_TIP)
                }
            }
            Text(CoachCopy.DISMISS, style = Typography.footnote, color = theme.textTertiary.color)
        }
    }
}

@Composable
private fun ZoneGuide(theme: ReaderTheme) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(Metrics.spacing24)) {
        Text(CoachCopy.ZONE_HEADLINE, style = Typography.headline, color = theme.text.color)
        Row(horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
            Zone(theme, Symbols.chevronLeft, "Back", "Left edge", Modifier.weight(1f))
            Zone(theme, Symbols.sliderHorizontal3, "Menu", "Middle", Modifier.weight(1f))
            Zone(theme, Symbols.chevronRight, "Forward", "Right edge", Modifier.weight(1f))
        }
        Tip(theme, Symbols.handPointUpLeft, CoachCopy.SELECT_TIP)
    }
}

@Composable
private fun Zone(theme: ReaderTheme, icon: Int, title: String, subtitle: String, modifier: Modifier) {
    val shape = RoundedCornerShape(Metrics.radiusMedium)
    Column(
        modifier
            .background(theme.text.withAlpha(0.06).color, shape)
            .border(1.dp, theme.text.withAlpha(0.12).color, shape)
            .padding(vertical = Metrics.spacing16),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Box(Modifier.height(26.dp), contentAlignment = Alignment.Center) {
            Icon(painterResource(icon), contentDescription = null, tint = theme.accent.color, modifier = Modifier.size(28.dp))
        }
        Text(title, style = Typography.subhead.copy(fontWeight = FontWeight.SemiBold), color = theme.text.color)
        Text(subtitle, style = Typography.caption, color = theme.textTertiary.color, textAlign = TextAlign.Center)
    }
}

@Composable
private fun Tip(theme: ReaderTheme, icon: Int, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing8)) {
        Icon(painterResource(icon), contentDescription = null, tint = theme.accent.color, modifier = Modifier.size(19.dp))
        Text(text, style = Typography.subhead, color = theme.textSecondary.color)
    }
}
