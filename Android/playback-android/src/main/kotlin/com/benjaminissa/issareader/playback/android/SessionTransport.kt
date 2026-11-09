package com.benjaminissa.issareader.playback.android

import android.os.Bundle
import androidx.annotation.OptIn
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.session.CommandButton
import androidx.media3.session.MediaSession
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionCommands
import com.benjaminissa.issareader.playback.CommandRouter
import java.util.Locale
import kotlin.math.abs

/**
 * Which buttons the system draws, from the bindings: Swift's
 * `RemoteCommandCenter.activate()`, as Media3 commands and button preferences.
 *
 * The switch iOS made by registering next/previous track or not is made here
 * by offering [Player.COMMAND_SEEK_TO_NEXT] and its kin or not. Offered, the
 * notification, the lock screen and Android Auto draw `⏮ ⏭` — the car's
 * default, where the wheel is the control that matters. Not offered, they
 * draw the interval skips in the same places, `⏪15` and `⏩30`, from the
 * button preferences below — the phone's default.
 *
 * The rate button is CarPlay's `CPNowPlayingPlaybackRateButton`: one press
 * moves through the speeds a driver wants, as there is no menu in a car.
 */
@OptIn(UnstableApi::class)
object SessionTransport {
    /** The rate button's command. */
    const val CYCLE_RATE = "com.benjaminissa.issareader.session.CYCLE_RATE"

    val cycleRate: SessionCommand = SessionCommand(CYCLE_RATE, Bundle.EMPTY)

    /** The track pair, offered only where the bindings use the wheel. */
    val trackCommands: List<Int> = listOf(
        Player.COMMAND_SEEK_TO_NEXT,
        Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
        Player.COMMAND_SEEK_TO_PREVIOUS,
        Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
    )

    /**
     * The player commands a controller is offered.
     *
     * @param usesTrackCommands the transport's switch; true when this surface
     *   binds the wheel.
     */
    fun playerCommands(usesTrackCommands: Boolean, available: Player.Commands = IssaSessionPlayer.AVAILABLE_COMMANDS): Player.Commands {
        if (usesTrackCommands) return available
        return available.buildUpon().removeAll(*trackCommands.toIntArray()).build()
    }

    /** Every command a controller may send, with the rate button's. */
    fun sessionCommands(base: SessionCommands = MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS): SessionCommands =
        base.buildUpon().add(cycleRate).build()

    /**
     * The buttons beside play: the skips where the track pair is not on
     * offer, and the rate button.
     *
     * @param transport what the router offers now; null while nothing is
     *   registered, when only the rate button is drawn.
     * @param rate the chosen speed, which the rate button names.
     */
    fun buttons(transport: CommandRouter.Transport?, rate: Double): List<CommandButton> {
        val buttons = mutableListOf<CommandButton>()
        if (transport != null && !transport.usesTrackCommands) {
            buttons += CommandButton.Builder(skipBackIcon(transport.skipBackwardInterval))
                .setPlayerCommand(Player.COMMAND_SEEK_BACK)
                .setDisplayName("Back ${seconds(transport.skipBackwardInterval)} seconds")
                .setSlots(CommandButton.SLOT_BACK)
                .build()
            buttons += CommandButton.Builder(skipForwardIcon(transport.skipForwardInterval))
                .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
                .setDisplayName("Forward ${seconds(transport.skipForwardInterval)} seconds")
                .setSlots(CommandButton.SLOT_FORWARD)
                .build()
        }
        buttons += CommandButton.Builder(CommandButton.ICON_PLAYBACK_SPEED)
            .setSessionCommand(cycleRate)
            .setDisplayName("Speed ${rateLabel(rate)}")
            .setSlots(CommandButton.SLOT_OVERFLOW)
            .build()
        return buttons
    }

    /**
     * The skip-back glyph for an interval: the numbered one where Media3 has
     * that number, the plain arrow otherwise. iOS printed whatever the
     * interval was on the button; a numbered glyph that names a different
     * interval would be a button that lies, so between the two the plain one
     * is the nearest honest glyph.
     */
    fun skipBackIcon(seconds: Double): Int = when (wholeSeconds(seconds)) {
        5 -> CommandButton.ICON_SKIP_BACK_5
        10 -> CommandButton.ICON_SKIP_BACK_10
        15 -> CommandButton.ICON_SKIP_BACK_15
        30 -> CommandButton.ICON_SKIP_BACK_30
        else -> CommandButton.ICON_SKIP_BACK
    }

    fun skipForwardIcon(seconds: Double): Int = when (wholeSeconds(seconds)) {
        5 -> CommandButton.ICON_SKIP_FORWARD_5
        10 -> CommandButton.ICON_SKIP_FORWARD_10
        15 -> CommandButton.ICON_SKIP_FORWARD_15
        30 -> CommandButton.ICON_SKIP_FORWARD_30
        else -> CommandButton.ICON_SKIP_FORWARD
    }

    /** A rate as the car reads it: "1×", "1.25×". */
    fun rateLabel(rate: Double): String {
        val rounded = Math.round(rate * 100) / 100.0
        val text = if (abs(rounded - Math.rint(rounded)) < 0.001) {
            String.format(Locale.ROOT, "%.0f", rounded)
        } else {
            String.format(Locale.ROOT, "%.2f", rounded).trimEnd('0')
        }
        return "$text×"
    }

    /** The rates the car's button moves through, wrapping round: CarPlay's list. */
    val carRates: List<Double> = listOf(1.0, 1.25, 1.5, 1.75, 2.0)

    /** The rate after [current] on [carRates], wrapping to the first. */
    fun nextCarRate(current: Double): Double = carRates.firstOrNull { it > current + 0.01 } ?: carRates[0]

    private fun wholeSeconds(seconds: Double): Int? =
        seconds.takeIf { it.isFinite() && abs(it - Math.rint(it)) < 0.001 }?.let { Math.rint(it).toInt() }

    private fun seconds(value: Double): String = wholeSeconds(value)?.toString() ?: String.format(Locale.ROOT, "%.1f", value)
}
