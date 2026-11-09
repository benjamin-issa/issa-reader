package com.benjaminissa.issareader.playback

import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * Reading a place off the coordinator without going there, and putting the
 * narration back to where it was before anything played.
 *
 * The player sheet opened on a read-along nobody has started drew the start
 * of the book, because the coordinator is built on open and holds nothing.
 * [ReadalongCoordinator.readout] is how the reader asks what the numbers would
 * be with the voice on a sentence, and [ReadalongCoordinator.clearPosition] is
 * how it gets back to the state where that question is the right one to ask.
 *
 * Both fixtures are used, for the shapes they add: the v3 book's holes and
 * audio chapters are entries whose start is not a sentence's. Ported from
 * `ReadalongClearTests.swift`.
 */
class ReadalongClearTest {
    // readout(at)

    /**
     * What the readout says is what the move then publishes. The sheet draws
     * these numbers before Play, and the coordinator publishes its own the
     * moment Play puts the voice there. They are one computation, so they are
     * equal to the last bit and the thumb does not move when Play is pressed.
     */
    @Test
    fun readoutIsWhatAMovePublishes() = runTest {
        for (v3 in listOf(false, true)) {
            val readalong = makeReadalong(backgroundScope, v3 = v3)
            val subject = readalong.subject
            try {
                // The clock off the player, so nothing but the move writes the numbers.
                subject.player.onTimeUpdate = null
                subject.player.onFinishedFile = null
                for (entry in readalong.timeline.entries) {
                    val predicted = subject.readout(entry)

                    assertTrue("${entry.fragmentId} did not load", subject.prepare(entry))

                    assertTrue(
                        "${entry.fragmentId}: ${predicted.bookProgress} said, ${subject.bookProgress} published",
                        abs(predicted.bookProgress - subject.bookProgress) < 1e-9,
                    )
                    val published = subject.chapterSpan
                    assertNotNull("${entry.fragmentId} is in a chapter the bar can describe", published)
                    assertEquals("${entry.fragmentId}: the chapter begins elsewhere", predicted.chapterSpan?.start, published?.start)
                    assertEquals("${entry.fragmentId}: the chapter runs for a different time", predicted.chapterSpan?.duration, published?.duration)
                }
            } finally {
                readalong.delete()
            }
        }
    }

    /**
     * Reading a place off leaves the coordinator where it was. A readout that
     * moved anything would be the cue the design rejected: it leaves a
     * sentence behind, and Play resumes pages back.
     */
    @Test
    fun readoutMovesNothing() = runTest {
        val readalong = makeReadalong(backgroundScope)
        val subject = readalong.subject
        try {
            val entry = readalong.timeline.entries[1]
            var told = 0
            subject.onFragmentChange = { told += 1 }
            subject.onChapterChange = { told += 1 }
            subject.onSeek = { told += 1 }

            val readout = subject.readout(entry)

            assertTrue("a sentence past the first has somewhere to be", readout.bookProgress > 0)
            assertNull(subject.activeEntry)
            assertNull(subject.activeFragmentId)
            assertEquals(0.0, subject.bookProgress, 0.0)
            assertNull(subject.chapterSpan)
            assertNull("nothing was loaded to read it", subject.player.currentAudioHref)
            assertFalse(subject.player.isPlaying)
            assertEquals("nobody was told anything moved", 0, told)
        } finally {
            readalong.delete()
        }
    }

    // clearPosition()

    /** Clearing leaves nothing lit, nothing playing and nothing loaded. */
    @Test
    fun clearLeavesNothing() = runTest {
        for (v3 in listOf(false, true)) {
            val readalong = makeReadalong(backgroundScope, v3 = v3)
            val subject = readalong.subject
            try {
                subject.player.onTimeUpdate = null
                subject.player.onFinishedFile = null
                val entry = readalong.timeline.entries[1]
                assertTrue(subject.play(entry))
                assertTrue(subject.activeEntry == entry && subject.player.isPlaying)
                assertEquals(entry.audioHref, subject.player.currentAudioHref)

                subject.clearPosition()

                assertNull(subject.activeEntry)
                assertNull(subject.activeFragmentId)
                assertEquals(0.0, subject.bookProgress, 0.0)
                assertNull(subject.chapterSpan)
                assertNull("no place left for the next save to record", subject.currentAnchor)
                assertFalse(subject.player.isPlaying)
                assertNull("the file is unloaded, not just forgotten", subject.player.currentAudioHref)
                assertEquals(0.0, subject.player.duration, 0.0)
                assertEquals(0.0, subject.player.currentTime, 0.0)
                assertTrue("and the engine holds no item", subject.player.engineTime.isNaN())
                assertEquals(0f, subject.player.engineRate)
            } finally {
                readalong.delete()
            }
        }
    }

    /**
     * A clock tick after clearing does not bring the sentence back. The reason
     * the file has to go with the entry: the player's clock fires on a pause
     * and on a seek, and `advance` re-derives the sentence from whichever file
     * the player still names.
     */
    @Test
    fun aTickAfterClearingDoesNotResurrect() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            val entry = readalong.timeline.entries[3]
            assertTrue(subject.play(entry))
            // Taken, and the real clock with it, so the one tick below is the
            // only one there is.
            val tick = detachClock(subject.player)
            subject.player.onFinishedFile = null
            var fragments = 0
            subject.onFragmentChange = { fragments += 1 }

            subject.clearPosition()
            tick(entry.start + 0.01)

            assertNull(subject.activeEntry)
            assertNull(subject.activeFragmentId)
            assertEquals(0.0, subject.bookProgress, 0.0)
            assertEquals("and the page was not told to light a sentence", 0, fragments)
        } finally {
            readalong.delete()
        }
    }

    /**
     * A file ending after clearing is not the end of the book. The end of a
     * file queued just before the clear, read as the end of the book, would
     * give the audio route away, which a stop does not mean to.
     */
    @Test
    fun aFileEndingAfterClearingIsNotTheEndOfTheBook() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            assertTrue(subject.prepare(readalong.timeline.entries[3]))
            subject.player.onTimeUpdate = null
            val ended = checkNotNull(subject.player.onFinishedFile) { "the coordinator listens for no file ending" }

            subject.clearPosition()
            ended()
            // The ending hops through a coroutine before it is answered.
            settle()

            assertEquals("the audio route was given back", 0, subject.player.sessionsEnded)
            assertNull(subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /** Playing after clearing opens the file again. */
    @Test
    fun playingAfterClearingReloads() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null
            val entry = readalong.timeline.entries[3]
            assertTrue(subject.play(entry))
            subject.clearPosition()

            // The same sentence of the same file, which is the case where a
            // player that still named its file would seek in an item that is
            // not there.
            assertTrue(subject.play(entry))

            assertEquals(entry, subject.activeEntry)
            assertEquals(entry.fragmentId, subject.activeFragmentId)
            assertEquals(entry.audioHref, subject.player.currentAudioHref)
            assertTrue(subject.player.isPlaying)
            assertTrue("an item is in the engine again", subject.player.engineTime.isFinite())
        } finally {
            readalong.delete()
        }
    }

    /**
     * A clear that lands while a move is opening its file is not undone by it.
     * The move is overtaken: finishing it would put the position back, and
     * `play` would press play over a player with nothing in it.
     */
    @Test
    fun aClearDuringAMoveSticks() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null
            val entry = readalong.timeline.entries[3]
            subject.player.whileLoadingAsset = { subject.clearPosition() }

            val played = subject.play(entry)

            assertFalse("the move was overtaken", played)
            assertFalse("and nothing was pressed to play", subject.player.isPlaying)
            assertNull(subject.activeEntry)
            assertNull(subject.activeFragmentId)
            assertEquals(0.0, subject.bookProgress, 0.0)
            assertNull(subject.player.currentAudioHref)
            assertEquals("the file that was opening is nobody's", 0.0, subject.player.duration, 0.0)
            assertEquals(0, subject.movesInFlight)

            // And the start after the stop is a start, not the one it overtook.
            assertTrue(subject.play(entry))
            assertEquals(entry, subject.activeEntry)
            assertTrue(subject.player.isPlaying)
        } finally {
            readalong.delete()
        }
    }

    /**
     * A clear that lands while a move is seeking in its file is not undone by
     * it: the same overtaking for a seek in a file the player already holds,
     * which is the other branch of `move`.
     */
    @Test
    fun aClearDuringASeekSticks() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null
            val entries = readalong.timeline.entries
            val first = entries[3]
            val sameFile = checkNotNull(entries.firstOrNull { it.audioHref == first.audioHref && it != first }) {
                "the fixture needs two sentences in one file"
            }
            assertTrue(subject.prepare(first))
            val seeking = async { subject.play(sameFile) }

            // The seek is awaiting the engine; this runs before it returns.
            yield()
            subject.clearPosition()
            val played = seeking.await()

            assertFalse(played)
            assertFalse(subject.player.isPlaying)
            assertNull(subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * Play with no sentence plays nothing: a coordinator nothing has started,
     * and one the reader cleared. Before, `resume` pressed `AudioPlayer.play`
     * anyway, which claimed the audio route and set `isPlaying` over a player
     * with no file in it, so the transport drew Pause over silence. The lock
     * screen's play and the player sheet past the last narrated chapter both
     * reach it.
     */
    @Test
    fun playWithNoSentencePlaysNothing() = runTest {
        for (cleared in listOf(false, true)) {
            val readalong = makeReadalong(backgroundScope, v3 = true)
            val subject = readalong.subject
            try {
                subject.player.onTimeUpdate = null
                subject.player.onFinishedFile = null
                if (cleared) {
                    assertTrue(subject.play(readalong.timeline.entries[3]))
                    subject.player.pause()
                    subject.clearPosition()
                }
                assertNull(subject.activeEntry)

                assertFalse(subject.resume())
                subject.perform(PlaybackAction.PLAY_PAUSE, CommandMap())
                subject.perform(PlaybackAction.PLAY, CommandMap())

                assertFalse("Play drew Pause over a player with nothing in it (cleared: $cleared)", subject.player.isPlaying)
                assertNull(subject.activeEntry)
            } finally {
                readalong.delete()
            }
        }
    }
}
