package com.benjaminissa.issareader.app.ui.player

import com.benjaminissa.issareader.playback.VolumeTrim
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Telling a reader their book cannot be made louder: Swift's
 * `VolumeTrimReachTests`.
 *
 * Without a gain stage the player can only make a book quieter, and the half
 * of the slider right of "as recorded" plays at the recorded level. Three
 * states and not two, which is the part worth pinning: null is "nothing
 * loaded yet", and captioning that would put the warning under every book for
 * the moment before its tracks resolve.
 */
class VolumeTrimReachTest {
    @Test
    fun `only a player that has answered no says no`() {
        for ((carriesGain, expected) in listOf(null to true, true to true, false to false)) {
            assertEquals("$carriesGain", expected, VolumeTrimReach.canBeLouder(carriesGain))
        }
    }

    @Test
    fun `the caption appears for that one state and no other`() {
        assertNull(VolumeTrimReach.caption(carriesGain = null))
        assertNull(VolumeTrimReach.caption(carriesGain = true))
        val caption = VolumeTrimReach.caption(carriesGain = false)
        assertNotNull(caption)
        assertTrue(caption!!.contains("quieter"))
    }

    /**
     * A screen reader has no caption to fall back on — the line under the
     * slider is hidden from it — so the value carries the warning, and only
     * where the level actually asks for more than can be delivered.
     */
    @Test
    fun `the spoken value warns above as-recorded and stays quiet at or below it`() {
        assertEquals("3 decibels louder", VolumeTrimReach.spoken(3, carriesGain = true))
        assertEquals("3 decibels louder", VolumeTrimReach.spoken(3, carriesGain = null))
        assertEquals("3 decibels louder, but this book can only be made quieter", VolumeTrimReach.spoken(3, carriesGain = false))
        assertEquals("1 decibel louder, but this book can only be made quieter", VolumeTrimReach.spoken(1, carriesGain = false))
        // Nothing is being lost at or below the recorded level, and a warning
        // there would be noise on every step of the working half.
        assertEquals("as recorded", VolumeTrimReach.spoken(0, carriesGain = false))
        assertEquals("6 decibels quieter", VolumeTrimReach.spoken(-6, carriesGain = false))
        // Through the clamp, so a stored level off the end is judged by the
        // rung it will actually play at.
        assertEquals("8 decibels louder, but this book can only be made quieter", VolumeTrimReach.spoken(Long.MAX_VALUE, carriesGain = false))
        assertEquals("8 decibels quieter", VolumeTrimReach.spoken(Long.MIN_VALUE, carriesGain = false))
    }

    /** Every rung, so the warning cannot be attached to the wrong half of the ladder by a stray comparison. */
    @Test
    fun `the warning is on exactly the rungs that cannot be heard`() {
        for (level in VolumeTrim.ladder) {
            val spoken = VolumeTrimReach.spoken(level, carriesGain = false)
            assertEquals("$level dB spoke as $spoken", level > 0, spoken.contains("can only be made quieter"))
            assertEquals(VolumeTrim.spoken(level), VolumeTrimReach.spoken(level, carriesGain = true))
        }
    }
}
