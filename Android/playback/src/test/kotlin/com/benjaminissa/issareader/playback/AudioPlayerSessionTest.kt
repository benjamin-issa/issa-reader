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

    /**
     * A start that awaits its file takes a token first and asks the player what
     * to do after. The system's pause is not the listener's: an interruption
     * that began while the file was opening must not count as one, or the book
     * is left silent with nothing to start it.
     */
    @Test
    fun anInterruptionDuringAStartIsNotTheListenersPause() = runTest {
        val (player, backend) = playing()
        player.pause()
        val before = player.pauses
        val token = player.startToken()

        backend.interruptionBegan()
        assertEquals("the system's pause was counted as the listener's", before, player.pauses)
        // The interruption is still going: nothing plays, and the wish is kept.
        assertFalse(player.playUnlessOvertaken(token))
        assertFalse("nothing plays over the interruption", player.isPlaying)

        backend.interruptionEnded(shouldResume = true)

        assertTrue("the interruption ended and the book was left silent", player.isPlaying)
        assertEquals(1f, player.engineRate)
    }

    /** An interruption that began and ended while the file opened: the start plays when the system expected it to. */
    @Test
    fun aStartSpanningAnInterruptionThatEndedWithResumePlays() = runTest {
        val (player, backend) = playing()
        player.pause()
        val token = player.startToken()

        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = true)

        assertTrue(player.playUnlessOvertaken(token))
        assertTrue(player.isPlaying)
    }

    /** ...and does not when the system said not to. */
    @Test
    fun aStartSpanningAnInterruptionThatEndedWithoutResumeDoesNotPlay() = runTest {
        val (player, backend) = playing()
        player.pause()
        val token = player.startToken()

        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = false)

        assertFalse(player.playUnlessOvertaken(token))
        assertFalse(player.isPlaying)
    }

    /** The listener's pause since the token is the last word, interruption or not. */
    @Test
    fun aPauseDuringAStartWinsOverItsTail() = runTest {
        val (player, _) = playing()
        player.pause()
        val token = player.startToken()
        player.pause()

        assertFalse(player.playUnlessOvertaken(token))
        assertFalse(player.isPlaying)
    }

    /** The reported fault: a listener's own Play during an interruption was swallowed. */
    @Test
    fun anExplicitPlayWhileInterruptedPlays() = runTest {
        val (player, backend) = playing()

        backend.interruptionBegan()
        assertFalse(player.isPlaying)
        player.play()

        assertTrue("the listener's Play was swallowed by the interruption", player.isPlaying)
        // It ended the interruption and cleared the latch: a later end does nothing more.
        player.pause()
        backend.interruptionEnded(shouldResume = true)
        assertFalse(player.isPlaying)
    }

    /** iOS-shaped: a began that is never followed by an end must not leave Play dead. */
    @Test
    fun anExplicitPlayAfterABeganWithNoEndPlays() = runTest {
        val (player, backend) = playing()
        player.pause()

        backend.interruptionBegan()
        player.play()

        assertTrue(player.isPlaying)
        assertEquals(1f, player.engineRate)
    }

    /** Ending the session during an interruption leaves nothing set that would make the next start defer. */
    @Test
    fun endSessionDuringAnInterruptionLeavesPlayWorking() = runTest {
        val (player, backend) = playing()
        backend.interruptionBegan()
        player.endSession()

        val token = player.startToken()
        player.play()
        assertTrue(player.isPlaying)
        player.pause()
        // And a start over a "still going" interruption that was ended by the session plays.
        backend.interruptionBegan()
        player.endSession()
        val later = player.startToken()
        assertTrue("a stuck interruption made the start defer", player.playUnlessOvertaken(later))
        assertTrue(token !== later)
    }

    /**
     * Permanent loss counts as the listener's pause: a start still opening its
     * file must not take the route back from the app that took it.
     */
    @Test
    fun aPermanentLossDuringAStartLeavesTheBookPaused() = runTest {
        val (player, backend) = playing()
        player.pause()
        val token = player.startToken()
        val activations = backend.sessionsActivated

        backend.focusLostForGood()

        assertFalse(player.playUnlessOvertaken(token))
        assertFalse(player.isPlaying)
        assertEquals("the start asked for the route back", activations, backend.sessionsActivated)
        // And the next Play is the listener's.
        player.play()
        assertTrue(player.isPlaying)
    }

    /** A Play refused during an interruption is kept for its end; outside one it is not. */
    @Test
    fun aPlayRefusedDuringAnInterruptionResumesAtItsEnd() = runTest {
        val (player, backend) = playing()
        player.pause()
        backend.interruptionBegan()
        backend.refusesSession = true
        player.play()
        assertFalse(player.isPlaying)

        backend.refusesSession = false
        backend.interruptionEnded(shouldResume = true)

        assertTrue("the refused Play was lost", player.isPlaying)
    }

    @Test
    fun aPauseAfterARefusedPlayDuringAnInterruptionWins() = runTest {
        val (player, backend) = playing()
        player.pause()
        backend.interruptionBegan()
        backend.refusesSession = true
        player.play()
        player.pause()
        backend.refusesSession = false
        backend.interruptionEnded(shouldResume = true)

        assertFalse(player.isPlaying)
    }

    @Test
    fun aPlayRefusedOutsideAnInterruptionIsNotKept() = runTest {
        val (player, backend) = playing()
        player.pause()
        backend.refusesSession = true
        player.play()
        backend.refusesSession = false
        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = true)

        assertFalse(player.isPlaying)
    }

    /** The listener's own pause during the interruption still has the last word. */
    @Test
    fun anExplicitPauseAfterAPlayAskedDuringAnInterruptionWins() = runTest {
        val (player, backend) = playing()
        player.pause()

        backend.interruptionBegan()
        player.play()
        player.pause()
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

    /**
     * A request for the audio route the system refuses leaves the player
     * paused. It used to draw Pause over silence, because the flag was set
     * after the request without asking how it went.
     */
    @Test
    fun aRefusedRouteLeavesThePlayerPaused() = runTest {
        val backend = ScriptedBackend()
        val player = scriptedPlayer(backend)
        player.load(AudioLocation.LocalFile(Silence.file), "silence.wav")
        backend.refusesSession = true

        player.play()

        assertFalse("the player said it was playing with no audio route", player.isPlaying)

        // The route comes back, and the next press plays.
        backend.refusesSession = false
        player.play()
        assertTrue(player.isPlaying)
    }

    /**
     * Android sends a second loss when a ducking request is followed by a
     * transient one. The second began with the player already paused by the
     * first, and recomputed the was-playing latch as false, so the one gain at
     * the end resumed nothing.
     */
    @Test
    fun aSecondInterruptionKeepsTheResume() = runTest {
        val (player, backend) = playing()

        backend.interruptionBegan()
        backend.interruptionBegan()
        assertFalse(player.isPlaying)
        backend.interruptionEnded(shouldResume = true)

        assertTrue("the second loss dropped the resume", player.isPlaying)
    }

    /** The latch still yields to an explicit pause made between two interruptions. */
    @Test
    fun aPauseBetweenTwoInterruptionsIsKept() = runTest {
        val (player, backend) = playing()

        backend.interruptionBegan()
        player.pause()
        backend.interruptionBegan()
        backend.interruptionEnded(shouldResume = true)

        assertFalse(player.isPlaying)
    }
}
