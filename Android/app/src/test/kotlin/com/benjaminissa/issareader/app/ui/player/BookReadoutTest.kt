package com.benjaminissa.issareader.app.ui.player

import com.benjaminissa.issareader.playback.PlaybackRate
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * How the player says how much of a book is left: Swift's `BookReadoutTests`.
 *
 * The line under the scrubber is `4h 12m left in book · 42%`, and the only
 * part of it with any logic is the duration. [PlayerText.timeText] prints
 * `4:12:00`, a correct clock reading and the wrong thing beside a scrubber —
 * a colon-separated figure reads as a position rather than an amount left —
 * so there is a second formatter, and this is what pins it.
 */
class BookReadoutTest {
    @Test
    fun `a length reads in units, not as a clock`() {
        for ((seconds, expected) in listOf(
            4 * 3600.0 + 12 * 60 to "4h 12m",
            47 * 60.0 to "47m",
            // On the hour, and the zero minutes are kept: "1h" alone next to
            // "4h 12m" reads like a different, coarser measurement.
            3600.0 to "1h 0m",
            0.0 to "0m",
        )) {
            assertEquals(expected, PlayerText.durationText(seconds))
        }
    }

    /** Rounded to the nearest minute rather than truncated, so 4h12m50s left does not claim 4h 12m for most of a minute. */
    @Test
    fun `seconds round rather than truncate`() {
        assertEquals("4h 13m", PlayerText.durationText(4 * 3600.0 + 12 * 60 + 50))
        assertEquals("4h 12m", PlayerText.durationText(4 * 3600.0 + 12 * 60 + 10))
    }

    /**
     * Nothing may reach a conversion that would trap, and a negative or
     * non-finite duration must not print a minus sign at a listener. `1e300`
     * is finite, so it walks past an `isFinite` guard.
     */
    @Test
    fun `nothing sensible comes back from a nonsense duration, and nothing crashes`() {
        for (nonsense in listOf(-60.0, Double.NaN, Double.POSITIVE_INFINITY, 1e300)) {
            assertEquals("0m", PlayerText.durationText(nonsense))
            assertEquals("no time", PlayerText.spokenDuration(nonsense))
        }
    }

    /** The clock above the bar, which reads a position rather than an amount. */
    @Test
    fun `a position reads as a clock, with the hour dropped under one`() {
        for ((seconds, expected) in listOf(
            0.0 to "0:00",
            7.0 to "0:07",
            67.0 to "1:07",
            47 * 60.0 + 31 to "47:31",
            4 * 3600.0 + 12 * 60 to "4:12:00",
            3600.0 to "1:00:00",
        )) {
            assertEquals(expected, PlayerText.timeText(seconds))
        }
    }

    /**
     * The same trap as the duration, in the same file. Both readings above
     * the scrubber are `total * progress` over a duration that came off the
     * wire, so this is the player failing as it draws rather than a wrong
     * number.
     */
    @Test
    fun `a nonsense position prints nothing rather than crashing the player`() {
        for (nonsense in listOf(1e300, Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, -60.0, 1e300 * 0.5, 1e300 * (1 - 0.5))) {
            assertEquals("0:00", PlayerText.timeText(nonsense))
        }
        // Still a real answer either side of the largest length a book has.
        assertEquals("99:00:00", PlayerText.timeText(99 * 3600.0))
    }

    /** A screen reader gets words: handed `4h 12m` it says "four aitch twelve em". */
    @Test
    fun `the spoken form is words, and singular where it should be`() {
        for ((seconds, expected) in listOf(
            4 * 3600.0 + 12 * 60 to "4 hours 12 minutes",
            3600.0 to "1 hour",
            60.0 to "1 minute",
            47 * 60.0 to "47 minutes",
            2 * 3600.0 + 60 to "2 hours 1 minute",
        )) {
            assertEquals(expected, PlayerText.spokenDuration(seconds))
        }
    }

    /** Two significant digits printed 1.25 as "1.2" and 1.75 as "1.8": a menu offering speeds the player never plays. */
    @Test
    fun `every rate on the ladder is printed as the rate it is`() {
        assertEquals(
            listOf("0.75×", "1×", "1.25×", "1.5×", "1.75×", "2×", "2.5×", "3×"),
            PlaybackRate.ladder.map(PlayerText::rateText),
        )
    }
}
