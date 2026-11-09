package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Test

// Ported from `PlaybackTests.swift` (`PlaybackRateTests`).

/** A playback rate is bounded wherever it comes from. */
class PlaybackRateTest {
    /**
     * The bound controls walked to 5.0× and down to 0.5× — speeds in no menu
     * anywhere, which the transport renders as "5×" — while the menus offered
     * 0.75 to 3.0 and the car stopped at 2.0. Three ceilings for one setting.
     */
    @Test
    fun boundsMatchTheLadder() {
        assertEquals(0.75, PlaybackRate.minimum, 0.0)
        assertEquals(3.0, PlaybackRate.maximum, 0.0)
        assertEquals(PlaybackRate.minimum, PlaybackRate.ladder.first(), 0.0)
        assertEquals(PlaybackRate.maximum, PlaybackRate.ladder.last(), 0.0)
    }

    /** Anything outside them is brought back. */
    @Test
    fun clampsOutOfRange() {
        for ((value, expected) in listOf(5.0 to 3.0, 0.5 to 0.75, 10.0 to 3.0, -1.0 to 0.75, 0.0 to 0.75)) {
            assertEquals("$value", expected, PlaybackRate.clamped(value), 0.0)
        }
    }

    /**
     * This value also arrives from the system's own speed control, which is
     * the system's to populate and was applied with no bound at all.
     */
    @Test
    fun refusesNonFinite() {
        assertEquals(1.0, PlaybackRate.clamped(Double.NaN), 0.0)
        assertEquals(1.0, PlaybackRate.clamped(Double.POSITIVE_INFINITY), 0.0)
    }

    /** A legal rate is untouched. */
    @Test
    fun leavesLegalRatesAlone() {
        for (rate in PlaybackRate.ladder) assertEquals(rate, PlaybackRate.clamped(rate), 0.0)
    }
}
