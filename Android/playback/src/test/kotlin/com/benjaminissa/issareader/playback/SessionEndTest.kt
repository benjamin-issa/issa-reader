package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `SessionEndTests.swift`, over the scripted engine.

/**
 * When listening is over, the audio route goes back to whoever had it.
 *
 * Taking the route stops the listener's music, and nothing ever gave it back,
 * so the app that was interrupted was never told it could resume. The end of
 * the book and the sleep timer are the ends of listening; an ordinary pause and
 * the hand-off to the reader are not.
 */
class SessionEndTest {
    /** The read-along running out at the end of the book ends the session; a pause does not. */
    @Test
    fun readalongEndOfBook() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            subject.player.onTimeUpdate = null
            val last = readalong.timeline.entries.last()

            // A pause, and the silent landing the car-to-reader hand-off makes.
            assertTrue(subject.prepare(last))
            subject.player.play()
            subject.player.pause()
            assertEquals("a pause keeps the route", 0, subject.player.sessionsEnded)

            subject.player.onFinishedFile?.invoke()
            assertTrue("the end of the book kept the audio route", settle { subject.player.sessionsEnded == 1 })
            assertEquals(1, readalong.backend.sessionsDeactivated)
            assertFalse(subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /** The audiobook running out of tracks ends the session; a track boundary does not. */
    @Test
    fun audiobookEndOfBook() = runTest {
        val subject = audiobook(backgroundScope, chunkManifest(2, 100.0))
        detachClock(subject.player)
        var loads = 0
        subject.onChapterChange = { loads += 1 }

        subject.seekToBookTime(50.0)
        subject.player.onFinishedFile?.invoke()
        assertTrue(settle { subject.trackIndex == 1 && loads >= 2 })
        assertEquals("the next track is not the end of the book", 0, subject.player.sessionsEnded)

        subject.player.onFinishedFile?.invoke()
        assertTrue("the end of the book kept the audio route", settle { subject.player.sessionsEnded == 1 })
    }
}

/**
 * A speed chosen from a bound control is reported as chosen, so the app can
 * remember it; a speed merely restored is not.
 */
class ChosenRateTest {
    /** Speed up and down, from either engine, report the speed they chose. */
    @Test
    fun boundSpeedActionsReportTheirChoice() = runTest {
        val map = CommandMap()
        val audiobook = audiobook(backgroundScope, chunkManifest(1, 100.0))
        val chosen = ArrayList<Float>()
        audiobook.player.onRateChosen = { chosen.add(it) }
        audiobook.perform(PlaybackAction.SPEED_UP, map)
        audiobook.perform(PlaybackAction.SPEED_DOWN, map)
        audiobook.perform(PlaybackAction.SPEED_DOWN, map)
        assertEquals(listOf(1.25f, 1.0f, 0.75f), chosen)

        val readalong = makeReadalong(backgroundScope)
        try {
            val readalongChosen = ArrayList<Float>()
            readalong.subject.player.onRateChosen = { readalongChosen.add(it) }
            readalong.subject.perform(PlaybackAction.SPEED_UP, map)
            assertEquals(listOf(1.25f), readalongChosen)
        } finally {
            readalong.delete()
        }
    }

    /** The saved speed applied when a book opens is not a new choice to save. */
    @Test
    fun aRestoredRateIsNotAChoice() {
        val player = scriptedPlayer()
        val chosen = ArrayList<Float>()
        player.onRateChosen = { chosen.add(it) }
        player.rate = 1.5f
        assertTrue(chosen.isEmpty())
    }
}
