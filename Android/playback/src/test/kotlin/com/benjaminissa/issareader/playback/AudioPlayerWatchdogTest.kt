package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The start check: narration the listener asked for, from an engine that
 * plays nothing.
 *
 * After a phone call on the iPhone, narration went silent while every button
 * said "playing". `isPlaying` here is the app's flag too, and nothing looked
 * at whether the engine followed. The engine's timer fires whether or not
 * audio moves, so each tick asks: meant to play, and the engine not playing
 * for a second? Nudge it once; if it still does not play, stop and say so.
 */
class AudioPlayerWatchdogTest {
    /** A player with a file placed and playing, and a clock the test moves by hand. */
    private class Harness {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        var now = 0.0
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

        /** One tick of the engine's timer, [seconds] after the last. */
        fun tick(seconds: Double = 1.0) {
            now += seconds
            backend.tick()
        }

        /** How many nudges the engine got: a zero followed by the rate again. */
        fun nudges(): Int = backend.rateWrites.zipWithNext().count { (a, b) -> a == 0f && b == player.rate }
    }

    /** A stuck engine is nudged once, then narration stops, says why, and tells the lock screen it stopped. */
    @Test
    fun aStuckEngineIsNudgedOnceThenStopped() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        harness.rates.clear()

        harness.tick() // first seen silent
        assertTrue(harness.player.isPlaying)
        assertEquals(0, harness.nudges())
        harness.tick() // a second on: nudged
        assertEquals(1, harness.nudges())
        assertTrue("stopped before its nudge had a chance", harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
        harness.tick() // a second after its nudge, still silent: stopped

        assertFalse("Pause was still drawn over silence", harness.player.isPlaying)
        assertTrue(harness.player.stoppedResponding)
        assertEquals(0f, harness.player.engineRate)
        assertEquals("the lock screen and the car were not told it stopped", 0f, harness.rates.last())
        assertEquals(
            "Narration stopped because this device's audio stopped responding. Press play to try again.",
            AudioPlayer.STOPPED_RESPONDING_MESSAGE,
        )
        harness.tick()
        harness.tick()
        assertEquals("nudged more than once", 1, harness.nudges())
    }

    /** Silence for less than a second is not a fault: the fine cadence ticks five times a second. */
    @Test
    fun aMomentOfSilenceIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        repeat(4) { harness.tick(0.2) }
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

    /** A paused player is meant to be silent. */
    @Test
    fun pausedIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.player.pause()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        repeat(5) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertFalse(harness.player.stoppedResponding)
    }

    /** An item that played to its end is silent while the next file opens: the read-along carries on across it. */
    @Test
    fun anEndedFileIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.finishItem()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        repeat(5) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertTrue("a file boundary cleared the intent the next file plays on", harness.player.isPlaying)
    }

    /** An interruption is the system's silence, not the engine's. */
    @Test
    fun anInterruptionIsLeftAlone() = runTest {
        val harness = Harness().playing()
        harness.backend.interruptionBegan()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        repeat(5) { harness.tick() }
        assertEquals(0, harness.nudges())
        assertFalse(harness.player.stoppedResponding)
    }

    /** An engine a nudge brings back keeps playing, and nothing is said. */
    @Test
    fun aRecoveredEngineKeepsPlaying() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        harness.backend.rateWrites.clear()
        harness.tick()
        harness.tick()
        assertEquals(1, harness.nudges())
        harness.backend.stuck = false
        repeat(5) { harness.tick() }
        assertTrue(harness.player.isPlaying)
        assertFalse(harness.player.stoppedResponding)
        assertEquals(1, harness.nudges())
    }

    /** A new play gets a nudge of its own, and takes the notice down. */
    @Test
    fun aNewPlayResetsTheCount() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        repeat(3) { harness.tick() }
        assertTrue(harness.player.stoppedResponding)
        assertFalse(harness.player.isPlaying)
        harness.backend.rateWrites.clear()

        harness.player.play()

        assertTrue(harness.player.isPlaying)
        assertFalse("the notice outlived the next play", harness.player.stoppedResponding)
        harness.tick()
        harness.tick()
        assertEquals("the new play got no nudge of its own", 1, harness.nudges())
        assertTrue(harness.player.isPlaying)
        harness.tick()
        assertFalse(harness.player.isPlaying)
    }

    /** The notice can be read and put away without pressing play. */
    @Test
    fun theNoticeCanBeDismissed() = runTest {
        val harness = Harness().playing()
        harness.backend.stuck = true
        repeat(3) { harness.tick() }
        assertTrue(harness.player.stoppedResponding)
        harness.player.dismissStoppedResponding()
        assertFalse(harness.player.stoppedResponding)
        assertFalse(harness.player.isPlaying)
    }
}
