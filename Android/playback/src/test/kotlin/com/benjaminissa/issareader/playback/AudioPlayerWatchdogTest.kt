package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The start check: narration the listener asked for, from an engine whose
 * playhead does not move.
 *
 * After a phone call on the iPhone, narration went silent while every button
 * said "playing". `isPlaying` here is the app's flag, and the engine's own
 * "playing" follows the same commands, so neither can see an output that has
 * stalled. The playhead can. The engine's timer fires whether or not audio
 * moves, so each tick asks: meant to play, and the position still for three
 * seconds? Nudge it once; if it is still for three more, stop and say so.
 */
class AudioPlayerWatchdogTest {
    /** A player with a file placed and playing, and a clock the test moves by hand. */
    private class Harness {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        var now = 0.0
        var position = 0.0
        val rates = ArrayList<Float>()

        init {
            player.clock = { now }
            player.setRateObserver(this) { rates.add(it) }
        }

        suspend fun playing(): Harness {
            assertEquals(AudioPlayer.LoadOutcome.LOADED, player.load(AudioLocation.LocalFile(Silence.file), "silence.wav"))
            player.play()
            assertTrue(player.isPlaying)
            return this
        }

        /** One tick of the engine's timer, [seconds] after the last, with the playhead moved by [moved]. */
        fun tick(seconds: Double = 1.0, moved: Double = 0.0) {
            now += seconds
            position += moved
            backend.tick(position)
        }

        /** How many nudges the engine got: a zero followed by the rate again. */
        fun nudges(): Int = backend.rateWrites.zipWithNext().count { (a, b) -> a == 0f && b == player.rate }
    }

    /** The engine says it is playing and the playhead stands still: nudged once after three seconds, stopped after three more. */
    @Test
    fun aFrozenPlayheadIsNudgedOnceThenStopped() = runTest {
        val harness = Harness().playing()
        harness.backend.rateWrites.clear()
        harness.rates.clear()
        assertTrue("the scripted engine should say it is playing", harness.backend.isPlaying)

        harness.tick() // first seen, at 0
        repeat(2) { harness.tick() } // two seconds still
        assertEquals("nudged before three seconds", 0, harness.nudges())
        harness.tick() // three seconds still: nudged
        assertEquals(1, harness.nudges())
        repeat(2) { harness.tick() }
        assertTrue("stopped before its nudge had three seconds", harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
        harness.tick() // three seconds after its nudge, still frozen: stopped

        assertFalse("Pause was still drawn over silence", harness.player.isPlaying)
        assertTrue(harness.player.stoppedResponding)
        assertEquals(0f, harness.player.engineRate)
        assertEquals("the lock screen and the car were not told it stopped", 0f, harness.rates.last())
        assertEquals(
            "Narration stopped because this device's audio stopped responding. Press play to try again.",
            AudioPlayer.STOPPED_RESPONDING_MESSAGE,
        )
        repeat(5) { harness.tick() }
        assertEquals("nudged more than once", 1, harness.nudges())
    }

    /** An engine that also says it is not playing is caught the same way. */
    @Test
    fun anEngineThatSaysItStoppedIsCaughtToo() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        repeat(7) { harness.tick() }
        assertTrue(harness.player.stoppedResponding)
        assertFalse(harness.player.isPlaying)
    }

    /** A playhead that moves is left alone, however long it plays. */
    @Test
    fun aMovingPlayheadIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.rateWrites.clear()
        repeat(30) { harness.tick(moved = 1.0) }
        repeat(30) { harness.tick(seconds = 0.2, moved = 0.1) }
        assertEquals(0, harness.nudges())
        assertTrue(harness.player.isPlaying)
    }

    /** Still for less than three seconds is not a fault: the fine cadence ticks five times a second. */
    @Test
    fun aMomentOfStillnessIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.rateWrites.clear()
        repeat(14) { harness.tick(0.2) }
        assertEquals(0, harness.nudges())
        assertTrue(harness.player.isPlaying)
    }

    /** A stream filling its buffer is waiting, not dead, however long it takes. */
    @Test
    fun bufferingIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.buffering = true
        harness.backend.rateWrites.clear()
        repeat(30) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertTrue(harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
    }

    /** A paused player is meant to be still. */
    @Test
    fun pausedIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.player.pause()
        harness.backend.rateWrites.clear()
        repeat(10) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertFalse(harness.player.stoppedResponding)
    }

    /** An item that played to its end is still while the next file opens: the read-along carries on across it. */
    @Test
    fun aFileBoundaryIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.finishItem()
        harness.backend.rateWrites.clear()
        repeat(10) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertTrue("a file boundary cleared the intent the next file plays on", harness.player.isPlaying)
    }

    /**
     * A seek to the very end of a file: the engine settles the seek and then
     * reports the ending. The ending must stand: clearing it as the seek
     * returned re-armed the check over an ended item.
     */
    @Test
    fun aSeekToTheEndIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.whileSeekSettles = { harness.backend.finishItem() }
        assertTrue(harness.player.seek(Silence.DURATION))
        harness.backend.whileSeekSettles = null
        harness.position = Silence.DURATION
        harness.backend.rateWrites.clear()
        repeat(10) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertTrue(harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
    }

    /** An interruption is the system's silence, not the engine's. */
    @Test
    fun anInterruptionIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.interruptionBegan()
        harness.backend.rateWrites.clear()
        repeat(10) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertFalse(harness.player.stoppedResponding)
    }

    /** An engine a nudge brings back keeps playing, and nothing is said. */
    @Test
    fun aRecoveredEngineKeepsPlaying() = runTest {
        val harness = Harness().playing()
        harness.backend.rateWrites.clear()
        repeat(4) { harness.tick() }
        assertEquals(1, harness.nudges())
        repeat(10) { harness.tick(moved = 1.0) }
        assertTrue(harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
        assertEquals(1, harness.nudges())
    }

    /** A new play gets a nudge of its own, and takes the notice down. */
    @Test
    fun aNewPlayResetsTheCount() = runTest {
        val harness = Harness().playing()
        repeat(7) { harness.tick() }
        assertTrue(harness.player.stoppedResponding)
        assertFalse(harness.player.isPlaying)
        harness.backend.rateWrites.clear()

        harness.player.play()

        assertTrue(harness.player.isPlaying)
        assertFalse("the notice outlived the next play", harness.player.stoppedResponding)
        repeat(4) { harness.tick() }
        assertEquals("the new play got no nudge of its own", 1, harness.nudges())
        assertTrue(harness.player.isPlaying)
        repeat(3) { harness.tick() }
        assertFalse(harness.player.isPlaying)
    }

    /** The notice can be read and put away without pressing play. */
    @Test
    fun theNoticeCanBeDismissed() = runTest {
        val harness = Harness().playing()
        repeat(7) { harness.tick() }
        assertTrue(harness.player.stoppedResponding)
        harness.player.dismissStoppedResponding()
        assertFalse(harness.player.stoppedResponding)
        assertFalse(harness.player.isPlaying)
    }
}
