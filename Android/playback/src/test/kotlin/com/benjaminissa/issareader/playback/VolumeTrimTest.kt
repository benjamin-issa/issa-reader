package com.benjaminissa.issareader.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs
import kotlin.math.log10

// Ported from `VolumeTrimTests.swift`. Swift's `Int` is 64-bit, so the
// magnitudes it is asked about are `Long`s here.

/**
 * One statement of what a per-book level may be.
 *
 * The slider, the keyboard shortcuts and the stored preference all reach this,
 * and each of them can hand it a value it did not ask for: a drag in flight, a
 * nudge off the end of the range, a preferences blob written by an older build.
 */
class VolumeTrimTest {
    /**
     * Snapped first, then clamped — and the order is only visible outside the
     * range, where the two disagree. Every integer decibel is a rung, so nothing
     * inside the range has anywhere to snap to; what the arithmetic is still for
     * is the values that arrive from outside it.
     */
    @Test
    fun stepping() {
        for ((input, expected) in listOf(
            0 to 0, 1 to 1, -1 to -1, 3 to 3, -6 to -6, 8 to 8, -8 to -8,
            9 to 8, -9 to -8, 100 to 8, -100 to -8, 500 to 8,
        )) {
            assertEquals("$input", expected, VolumeTrim.clamped(input))
        }
    }

    /**
     * Whatever a caller hands it, what comes back is a level the slider can draw
     * and the ladder contains. The sweep is wider than the range on purpose: the
     * percentages a previous build stored ran to ±50.
     */
    @Test
    fun alwaysLandsOnTheLadder() {
        assertEquals(17, VolumeTrim.ladder.size)
        assertEquals(-8, VolumeTrim.ladder.first())
        assertEquals(8, VolumeTrim.ladder.last())
        assertEquals("a rung is not a fixed point of the clamp", VolumeTrim.ladder, VolumeTrim.ladder.map { VolumeTrim.clamped(it) })
        for (level in -60..60) {
            assertTrue("$level clamped to something the slider cannot show", VolumeTrim.clamped(level) in VolumeTrim.ladder)
        }
    }

    /** The ends of the range are the ends of the gain range. */
    @Test
    fun gains() {
        assertEquals(1f, VolumeTrim.gain(0))
        assertTrue(abs(VolumeTrim.gain(8) - 2.511_886_4f) < 1e-5f)
        assertTrue(abs(VolumeTrim.gain(-8) - 0.398_107_2f) < 1e-5f)
        assertEquals(VolumeTrim.gainRange.endInclusive, VolumeTrim.gain(8))
        assertEquals(VolumeTrim.gainRange.start, VolumeTrim.gain(-8))
        // Out of range on the way in, in range on the way out: a nudge past the
        // end must not be allowed to leak a gain past the end.
        assertEquals(VolumeTrim.gain(8), VolumeTrim.gain(500))
    }

    /**
     * The reason the scale changed, and the assertion no range or bounds test
     * can make. On the percentage scale it shipped at, −50 → −45% was 0.83 dB
     * while +45 → +50% was 0.29 dB — and the just-noticeable difference on
     * speech is about 1 dB, so every detent on the upper half did nothing a
     * reader could hear. Here every click is the same size, and that size is one
     * JND.
     */
    @Test
    fun everyRungIsTheSameSize() {
        for ((lower, upper) in VolumeTrim.ladder.zip(VolumeTrim.ladder.drop(1))) {
            val step = 20 * log10((VolumeTrim.gain(upper) / VolumeTrim.gain(lower)).toDouble())
            assertTrue("$lower dB → $upper dB is a step of $step dB", abs(step - 1) < 0.05)
        }
        // And the top rung is the "up to 150% louder" that was asked for.
        assertTrue(abs((VolumeTrim.gain(8) - 1) * 100 - 151.2f) < 0.5f)
    }

    /**
     * A NaN reaching the gain stage would multiply every sample into nothing,
     * with no control on screen able to explain or undo it.
     */
    @Test
    fun nonFiniteGain() {
        assertEquals(1f, VolumeTrim.clampedGain(Float.NaN))
        assertEquals(1f, VolumeTrim.clampedGain(Float.POSITIVE_INFINITY))
        assertEquals(1f, VolumeTrim.clampedGain(Float.NEGATIVE_INFINITY))
        assertEquals(VolumeTrim.gainRange.endInclusive, VolumeTrim.clampedGain(9f))
        assertEquals(VolumeTrim.gainRange.start, VolumeTrim.clampedGain(0f))
        assertEquals(1.1f, VolumeTrim.clampedGain(1.1f))
    }

    /**
     * Every level a shipped build could have written, converted, and measured
     * against the multiplier the reader was actually hearing. The rounding to
     * the nearest rung is what moves it, and half a decibel is half a
     * just-noticeable difference: nobody hears the upgrade happen.
     */
    @Test
    fun legacyPercentagesKeepTheirMeaning() {
        var worst = 0.0
        for (percent in -50..50 step 5) {
            val wasPlayingAt = 1 + percent.toDouble() / 100
            val nowPlaysAt = VolumeTrim.gain(VolumeTrim.decibels(forLegacyPercent = percent)).toDouble()
            val shift = abs(20 * log10(nowPlaysAt / wasPlayingAt))
            worst = maxOf(worst, shift)
            assertTrue("$percent% moved by $shift dB", shift < 0.5)
        }
        assertTrue("the worst shift is not where it was measured, $worst", abs(worst - 0.4988) < 0.001)
    }

    /**
     * The values that matter most, spelled out: the two ends of the old slider
     * and the ±30% it shipped at before that.
     */
    @Test
    fun namedLegacyLevels() {
        for ((percent, decibels) in listOf(
            -50 to -6, -30 to -3, -25 to -2, -15 to -1, 0 to 0, 5 to 0,
            15 to 1, 25 to 2, 30 to 2, 50 to 4,
        )) {
            assertEquals("$percent%", decibels, VolumeTrim.decibels(forLegacyPercent = percent))
        }
    }

    /**
     * A blob on disk is a file, and a file can say anything. −100% is silence and
     * anything under it is a phase inversion; neither was ever a level a control
     * offered, and `log10` of either is not a number an integer can hold.
     */
    @Test
    fun absurdLegacyPercentages() {
        for (percent in listOf(-100L, -101L, -1000L, Long.MIN_VALUE / 2, 1000L, Long.MAX_VALUE / 2)) {
            assertTrue("$percent", VolumeTrim.decibels(forLegacyPercent = percent) in VolumeTrim.range)
        }
    }

    /**
     * The magnitudes `clamped` exists to sanitise, which the Swift version used
     * to crash on: it converted through `Double` before clamping, and
     * `Double(Int.max)` rounds up to one past `Int.max`. Every stored level runs
     * through here while the app is starting, so the crash was on the launch
     * path and a hand-edited or truncated blob was all it took.
     */
    @Test
    fun clampsRatherThanTrapping() {
        for (stored in listOf(
            Long.MAX_VALUE, Long.MIN_VALUE, Long.MAX_VALUE - 1, Long.MIN_VALUE + 1,
            Int.MAX_VALUE.toLong(), Int.MIN_VALUE.toLong(), 9_007_199_254_740_993L, -9_007_199_254_740_993L,
            1_000_000L, -1_000_000L, 9L, -9L,
        )) {
            val legal = VolumeTrim.clamped(stored)
            assertTrue(legal in VolumeTrim.range)
            assertTrue("$stored landed off the ladder at $legal", legal in VolumeTrim.ladder)
            assertTrue(
                legal == (if (stored > 0) VolumeTrim.range.last else VolumeTrim.range.first) ||
                    stored in VolumeTrim.range.first.toLong()..VolumeTrim.range.last.toLong(),
            )
        }
    }

    /**
     * The two ends specifically, because they are the values a corrupted blob is
     * most likely to hold and the exact pair the old arithmetic died on.
     */
    @Test
    fun extremesLandOnTheEnds() {
        assertEquals(8, VolumeTrim.clamped(Long.MAX_VALUE))
        assertEquals(-8, VolumeTrim.clamped(Long.MIN_VALUE))
        // And through the two callers that hand a stored number straight on.
        assertEquals(VolumeTrim.gainRange.endInclusive, VolumeTrim.gain(Long.MAX_VALUE))
        assertEquals(VolumeTrim.gainRange.start, VolumeTrim.gain(Long.MIN_VALUE))
        assertEquals("+8 dB", VolumeTrim.label(Long.MAX_VALUE))
        assertEquals("8 decibels quieter", VolumeTrim.spoken(Long.MIN_VALUE))
    }

    /**
     * The legacy key holds an integer too, and it is read on the same launch.
     * `1 + MAX / 100` is finite, so the conversion below it has to hold as well.
     */
    @Test
    fun legacyPercentDoesNotTrap() {
        for (percent in listOf(Long.MAX_VALUE, Long.MIN_VALUE, Long.MAX_VALUE - 1, Long.MIN_VALUE + 1, 1_000_000L, -1_000_000L)) {
            assertTrue(VolumeTrim.decibels(forLegacyPercent = percent) in VolumeTrim.range)
        }
    }

    /** The label reads as recorded at zero and signs itself either side. */
    @Test
    fun labels() {
        assertEquals("As recorded", VolumeTrim.label(0))
        assertEquals("+3 dB", VolumeTrim.label(3))
        // U+2212 MINUS SIGN, which is what sits level with the plus in a
        // monospaced-digit face. A hyphen would be shorter and lower.
        assertEquals("−6 dB", VolumeTrim.label(-6))
        assertFalse(VolumeTrim.label(-6).contains("-"))
        assertEquals("−8 dB", VolumeTrim.label(-8))
        assertEquals("+8 dB", VolumeTrim.label(8))
        // The row's ticks are read off the range, so widening it cannot leave the
        // slider going one place and its own captions promising another.
        assertEquals("−8 dB", VolumeTrim.label(VolumeTrim.range.first))
        assertEquals("+8 dB", VolumeTrim.label(VolumeTrim.range.last))
    }

    /** The spoken form says which way the sound moves. */
    @Test
    fun spoken() {
        assertEquals("as recorded", VolumeTrim.spoken(0))
        assertEquals("3 decibels louder", VolumeTrim.spoken(3))
        assertEquals("6 decibels quieter", VolumeTrim.spoken(-6))
        assertEquals("8 decibels quieter", VolumeTrim.spoken(-8))
        assertEquals("8 decibels louder", VolumeTrim.spoken(8))
        // The step is one decibel, so ±1 is the first rung either side of "as
        // recorded" and the one a reader lands on most.
        assertEquals("1 decibel louder", VolumeTrim.spoken(1))
        assertEquals("1 decibel quieter", VolumeTrim.spoken(-1))
    }
}
