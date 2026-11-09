package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Android's own. The Swift suites could not stage an interruption or a route
// change without a device; the scripted engine can, so the decisions
// `AudioPlayer` makes about them are pinned here.

/** What stops audio without the app asking, and what the player does about it. */
class AudioPlayerSessionTest {
    private suspend fun playing(): Pair<AudioPlayer, ScriptedBackend> {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        player.load(AudioLocation.LocalFile(Silence.file), "silence.wav")
        player.play()
        return player to backend
    }

    /** A call interrupts; when it ends, a listener who was listening is listening again. */
    @Test
    fun anInterruptionPausesAndResumes() = runTest {
        val (player, backend) = playing()
        val told = ArrayList<Boolean>()
        player.onInterruption = { told.add(it) }

        backend.interruptionBegan()
        assertFalse(player.isPlaying)
        assertEquals(0f, player.engineRate)

        backend.interruptionEnded(shouldResume = true)
        assertTrue(player.isPlaying)
        assertEquals(1f, player.engineRate)
        assertEquals(listOf(false, true), told)
    }

    /**
     * A listener who took a call and then deliberately paused had the book start
     * again by itself when the call ended, against an explicit instruction.
     */
    @Test
    fun aPauseDuringAnInterruptionIsKept() = runTest {
        val (player, backend) = playing()

        backend.interruptionBegan()
        player.pause()
        backend.interruptionEnded(shouldResume = true)

        assertFalse(player.isPlaying)
    }

    /**
     * Spent, either way: a second end with no intervening beginning — which the
     * system does deliver — resumed a book the listener had stopped.
     */
    @Test
    fun aSecondEndResumesNothing() = runTest {
        val (player, backend) = playing()

        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = false)
        assertFalse("the system did not expect playback to carry on", player.isPlaying)
        backend.interruptionEnded(shouldResume = true)
        assertFalse(player.isPlaying)
    }

    /** An interruption that arrives while paused does not start the book when it ends. */
    @Test
    fun anInterruptionWhilePausedResumesNothing() = runTest {
        val (player, backend) = playing()
        player.pause()

        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = true)

        assertFalse(player.isPlaying)
    }

    /**
     * Unplugging headphones is a route change, and the convention is to pause
     * rather than start playing a book out loud in a quiet room.
     */
    @Test
    fun aLostRoutePauses() = runTest {
        val (player, backend) = playing()
        var lost = 0
        player.onRouteLoss = { lost += 1 }

        backend.routeLost()

        assertFalse(player.isPlaying)
        assertEquals(0f, player.engineRate)
        assertEquals(1, lost)
    }

    /**
     * The route is taken when the listener asks for narration, not when a book is
     * merely opened, and given back only at the ends of listening.
     */
    @Test
    fun theRouteIsTakenOnPlayAndGivenBackAtTheEnd() = runTest {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        assertEquals("declared, not taken", 1, backend.sessionsConfigured)
        assertEquals(0, backend.sessionsActivated)

        player.load(AudioLocation.LocalFile(Silence.file), "silence.wav")
        assertEquals("opening a book takes nothing", 0, backend.sessionsActivated)
        player.play()
        assertEquals(1, backend.sessionsActivated)
        player.pause()
        assertEquals("a pause keeps the route", 0, backend.sessionsDeactivated)
        player.endSession()
        assertEquals(1, backend.sessionsDeactivated)
    }

    /** The clock observes at a second with the screen off, and at a fifth of one while a reader follows it. */
    @Test
    fun theClockCadence() {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        assertEquals(AudioPlayer.IDLE_OBSERVATION_INTERVAL, backend.observationInterval)
        player.setHighFrequencyUpdates(true)
        assertEquals(0.2, checkNotNull(backend.observationInterval), 0.0)
        player.setHighFrequencyUpdates(false)
        assertEquals(1.0, checkNotNull(backend.observationInterval), 0.0)
    }

    /**
     * A time that is not a number reaches nothing: the observer keeps firing
     * across a track change, when there is no item and the engine's time is NaN.
     */
    @Test
    fun aClockWithNoItemReportsNothing() = runTest {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        val heard = ArrayList<Double>()
        player.onTimeUpdate = { heard.add(it) }

        backend.tick(Double.NaN)
        assertTrue(heard.isEmpty())

        player.load(AudioLocation.LocalFile(Silence.file), "silence.wav")
        backend.tick(12.5)
        assertEquals(listOf(12.5), heard)
        assertEquals(12.5, player.currentTime, 0.0)
    }

    /** The end of an item reaches the coordinator; an item a later load replaced says nothing more. */
    @Test
    fun theEndOfAnItemIsReported() = runTest {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        var ended = 0
        player.onFinishedFile = { ended += 1 }

        player.load(AudioLocation.LocalFile(Silence.file), "one.wav")
        backend.finishItem()
        assertEquals(1, ended)
    }

    /** A failure reported by the engine stops the player once, and names nothing loaded. */
    @Test
    fun anEngineFailureStopsThePlayer() = runTest {
        val (player, backend) = playing()

        backend.failItem("the stream went away")

        assertFalse(player.isPlaying)
        assertTrue(player.itemHasFailed)
        assertEquals(null, player.currentAudioHref)
        player.play()
        assertFalse("play over a dead item claims nothing", player.isPlaying)
    }
}
