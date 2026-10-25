package com.benjaminissa.issareader.app.ui.player

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.playback.PlaybackDriving
import com.benjaminissa.issareader.playback.VolumeTrim
import com.benjaminissa.issareader.ui.Metrics
import com.benjaminissa.issareader.ui.Palette
import com.benjaminissa.issareader.ui.Typography
import kotlin.math.roundToInt

/**
 * The one place a book's level is changed.
 *
 * Both halves of the change happen together — the stored preference, so it
 * survives the app, and the running player, so it is audible while the slider
 * is still under the reader's thumb. Writing the pair by hand at each caller
 * is how one of them ends up persisting a level nothing plays at.
 */
object VolumeTrimControl {
    fun set(decibels: Int, book: Book, coordinator: PlaybackDriving?, settings: PlaybackSettings) {
        val legal = VolumeTrim.clamped(decibels)
        settings.setVolumeTrim(legal, book.uuid)
        // Whatever is playing this book right now. Null when nothing is, which
        // is a perfectly ordinary way to set a level in advance.
        coordinator?.player?.gain = VolumeTrim.gain(legal)
    }

    /**
     * Moves the level by one decibel, from wherever it is: read from the
     * preference rather than the player, whose gain going back and forth
     * through the multiplier would accumulate the error the detents prevent.
     */
    fun nudge(delta: Int, book: Book, coordinator: PlaybackDriving?, settings: PlaybackSettings) {
        set(settings.volumeTrim(book.uuid) + delta, book, coordinator, settings)
    }
}

/**
 * "Volume for this book": the row under the transport.
 *
 * Per book rather than global, because the problem it solves is a library
 * whose files disagree with each other: a self-hosted shelf is assembled from
 * whatever could be found, and one book being six decibels under the next is
 * not something a single app-wide setting can answer.
 */
@Composable
internal fun VolumeTrimRow(book: Book, coordinator: PlaybackDriving?, settings: PlaybackSettings, modifier: Modifier = Modifier) {
    val trim = settings.volumeTrim(book.uuid)
    // Null when nothing is playing this book — the case the whole row is
    // disabled for. Otherwise the player's own answer.
    val carriesGain: Boolean? = coordinator?.player?.tapCarriesGain
    val enabled = coordinator != null
    val haptics = LocalHapticFeedback.current
    // A tap at the centre detent, because "as recorded" is the value the
    // reader is most often trying to get back to, and the track gives no
    // other sign of passing it.
    var previous by remember { mutableStateOf(trim) }
    LaunchedEffect(trim) {
        if (trim == 0 && previous != 0) haptics.performHapticFeedback(HapticFeedbackType.SegmentTick)
        previous = trim
    }

    Column(
        modifier.fillMaxWidth().padding(horizontal = Metrics.spacing8),
        verticalArrangement = Arrangement.spacedBy(Metrics.spacing8),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(Metrics.spacing12)) {
            Text("Volume for this book", style = Typography.subhead, color = Palette.ink, modifier = Modifier.weight(1f))
            // Only once the book has departed from the recording: a reset
            // beside "As recorded" would be a control that cannot do anything.
            if (trim != 0) {
                Text(
                    "Reset",
                    style = Typography.subhead,
                    color = Palette.tangerine,
                    modifier = Modifier
                        .clickable(enabled = enabled, role = Role.Button) { VolumeTrimControl.set(0, book, coordinator, settings) }
                        .semantics { contentDescription = "Reset volume for this book" },
                )
            }
            // Tabular figures, so the value does not shuffle the row sideways
            // as it steps through the rungs.
            Text(VolumeTrim.label(trim), style = Typography.subhead.copy(fontFeatureSettings = "tnum"), color = Palette.inkSecondary)
        }

        Slider(
            value = trim.toFloat(),
            onValueChange = { VolumeTrimControl.set(it.roundToInt(), book, coordinator, settings) },
            valueRange = VolumeTrim.range.first.toFloat()..VolumeTrim.range.last.toFloat(),
            steps = (VolumeTrim.range.last - VolumeTrim.range.first) / VolumeTrim.STEP - 1,
            enabled = enabled,
            colors = PlayerControls.sliderColors(),
            modifier = Modifier
                .fillMaxWidth()
                // "−6 dB" is read as "minus six D B", which says nothing about
                // which way the sound moves.
                .semantics {
                    contentDescription = "Volume for this book"
                    stateDescription = VolumeTrimReach.spoken(trim, carriesGain)
                },
        )

        // Both ends read off the range rather than typed out, so widening it
        // cannot leave the slider going one place and its own ticks another.
        Row(Modifier.fillMaxWidth().clearAndSetSemantics {}) {
            Text(VolumeTrim.label(VolumeTrim.range.first), style = Typography.caption, color = Palette.inkTertiary)
            Spacer(Modifier.weight(1f))
            Text("as recorded", style = Typography.caption, color = Palette.inkTertiary)
            Spacer(Modifier.weight(1f))
            Text(VolumeTrim.label(VolumeTrim.range.last), style = Typography.caption, color = Palette.inkTertiary)
        }

        // The quieter half still works, and the level is worth keeping for
        // when the same book is played from a file, so this is said rather
        // than disabled.
        VolumeTrimReach.caption(carriesGain)?.let { caption ->
            Text(
                caption,
                style = Typography.caption,
                color = Palette.inkTertiary,
                modifier = Modifier.fillMaxWidth().clearAndSetSemantics {},
            )
        }
    }
}

/**
 * What the volume row says about a level it cannot deliver.
 *
 * Without a gain stage on the stream the player can only make a book quieter:
 * everything right of "as recorded" plays at the recorded level. The
 * arithmetic is right — there is nowhere else for the level to come from — but
 * it was silent, and a reader dragging to the top heard nothing change and had
 * no way to tell that from a broken control.
 *
 * Three states, not two: null is "not yet known", and treating it as a refusal
 * would caption every book for the moment before its tracks resolve.
 */
object VolumeTrimReach {
    /** Whether the louder half of the slider can actually be heard. */
    fun canBeLouder(carriesGain: Boolean?): Boolean = carriesGain != false

    /** The line under the slider, or null when there is nothing to explain. */
    fun caption(carriesGain: Boolean?): String? {
        if (canBeLouder(carriesGain)) return null
        return "This book can only be made quieter. It is being streamed, and only a downloaded file can be played louder than it was recorded."
    }

    /**
     * What a screen reader reads as the slider's value, with the caption
     * folded in — only where the level asks for more than can be delivered.
     */
    fun spoken(decibels: Long, carriesGain: Boolean?): String {
        val level = VolumeTrim.spoken(decibels)
        if (canBeLouder(carriesGain) || VolumeTrim.clamped(decibels) <= 0) return level
        return "$level, but this book can only be made quieter"
    }

    fun spoken(decibels: Int, carriesGain: Boolean?): String = spoken(decibels.toLong(), carriesGain)
}
