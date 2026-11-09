package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs

// Ported from `DeadItemTests.swift`, over the scripted engine.

/**
 * A file that would not open is not something to press play over.
 *
 * `load` already stopped the player the first time a file failed, and said
 * `FAILED`. Everything after that went on as if it had not: the player kept the
 * dead item and its href, `play()` never looked, and the next press — a second
 * tap of the button, a tap on another sentence in the same file, a play command
 * from the lock screen or the car — took the audio route, stopped whatever the
 * listener had been hearing, and drew a pause glyph over silence that nothing
 * ever stood down.
 */
class DeadItemTest {
    /** A file the engine cannot open, at a path the test can later fill. */
    private fun missing(extension: String = "wav"): File =
        File(System.getProperty("java.io.tmpdir"), "issa-dead-item-${UUID.randomUUID()}.$extension")

    // The player

    /** R-10. The press after the failure, which used to be the one that claimed playback. */
    @Test
    fun playOverAFailedItemClaimsNothing() = runTest {
        val player = scriptedPlayer()
        val rates = ArrayList<Float>()
        val owner = Any()
        player.setRateObserver(owner) { rates.add(it) }

        val outcome = player.load(AudioLocation.LocalFile(missing()), "dead.wav")
        assertEquals(AudioPlayer.LoadOutcome.FAILED, outcome)
        rates.clear()

        player.play()

        assertFalse("a player holding a dead item said it was playing", player.isPlaying)
        assertEquals(0f, player.engineRate)
        assertTrue("the lock screen and the app were told it started: $rates", rates.all { it == 0f })
        assertNull("the dead file is still named as the one loaded", player.currentAudioHref)
        assertTrue(player.itemHasFailed)
    }

    /** The other half of "nothing is claimed": the next load is a fresh item, and plays. */
    @Test
    fun aLoadAfterAFailurePlays() = runTest {
        val player = scriptedPlayer()
        assertEquals(AudioPlayer.LoadOutcome.FAILED, player.load(AudioLocation.LocalFile(missing()), "dead.wav"))

        assertEquals(AudioPlayer.LoadOutcome.LOADED, player.load(AudioLocation.LocalFile(Silence.file), "silence.wav"))
        player.play()

        assertTrue(player.isPlaying)
        assertFalse(player.itemHasFailed)
        assertEquals("silence.wav", player.currentAudioHref)
    }

    /**
     * R-48. The item fails while the load's own trailing seek is still to land.
     * `itemDidFail` stood the player down, but the seek still owned the playhead
     * and came back true, so the load reported `LOADED` for a dead item and its
     * caller pressed play over it.
     */
    @Test
    fun aFailureDuringTheTrailingSeek() = runTest {
        val player = scriptedPlayer()
        player.beforeTrailingSeek = { player.itemDidFail(player.itemGenerationForTests, "test") }

        val outcome = player.load(AudioLocation.LocalFile(Silence.file), "silence.wav", startAt = 30.0)

        assertEquals("a load whose item failed under its seek said $outcome", AudioPlayer.LoadOutcome.FAILED, outcome)
        player.play()
        assertFalse(player.isPlaying)
    }

    /**
     * The same, reported by the engine rather than by hand: the item stops for
     * good while its trailing seek is pending, and the load must say so.
     */
    @Test
    fun anEngineFailureDuringTheTrailingSeek() = runTest {
        val player = scriptedPlayer()
        player.beforeTrailingSeek = { player.scripted.failItem("the stream went away") }

        val outcome = player.load(AudioLocation.LocalFile(Silence.file), "silence.wav", startAt = 30.0)

        assertEquals(AudioPlayer.LoadOutcome.FAILED, outcome)
        assertTrue(player.itemHasFailed)
    }

    // The read-along

    /** Two sentences in one file that will not open. */
    private fun readalong(file: File, scope: CoroutineScope): Pair<ReadalongCoordinator, SmilTimeline> {
        val chapter = "OEBPS/ch1.xhtml"
        val audio = "OEBPS/Audio/a.wav"
        val timeline = SmilTimeline(
            listOf(
                SmilEntry("s1", chapter, audio, 0.0, 5.0, 5.0),
                SmilEntry("s2", chapter, audio, 5.0, 10.0, 10.0),
            ),
        )
        return ReadalongCoordinator(timeline, mapOf(audio to file), scriptedPlayer(), scope) to timeline
    }

    /**
     * R-10, as the reader meets it: the first press fails honestly; the second
     * press, and a tap on the next sentence of the same file, used to take the
     * same-file branch — seek a dead item, say it landed, and play.
     */
    @Test
    fun aReadalongDoesNotPlayOverADeadFile() = runTest {
        val (subject, timeline) = readalong(missing(), backgroundScope)
        val first = timeline.entries[0]
        val second = timeline.entries[1]

        assertFalse(subject.play(first))
        subject.perform(PlaybackAction.PLAY_PAUSE, CommandMap())
        assertFalse("the second press played over a dead file", subject.player.isPlaying)

        assertFalse("a sentence in the dead file said it played", subject.play(second))
        assertFalse(subject.player.isPlaying)

        subject.perform(PlaybackAction.PLAY, CommandMap())
        assertFalse("the lock screen's play played over a dead file", subject.player.isPlaying)
    }

    /**
     * A press on a dead item is a retry, not a no-op: the file is opened again,
     * so narration whose file has come back plays.
     */
    @Test
    fun aPressRetriesTheFile() = runTest {
        val file = missing()
        try {
            val (subject, timeline) = readalong(file, backgroundScope)
            assertFalse(subject.play(timeline.entries[0]))

            Silence.file.copyTo(file)
            subject.perform(PlaybackAction.PLAY_PAUSE, CommandMap())

            assertTrue(subject.player.isPlaying)
            assertFalse("it played over the dead item rather than reopening the file", subject.player.itemHasFailed)
            assertEquals(timeline.entries[0].audioHref, subject.player.currentAudioHref)
            assertEquals(timeline.entries[0], subject.activeEntry)
        } finally {
            file.delete()
        }
    }

    // The audiobook

    private fun manifest(): AudiobookManifest = AudiobookManifest(
        metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Two Tracks")),
        readingOrder = listOf(
            AudiobookManifest.Track(href = "track0.wav", type = "audio/wav", duration = 600.0),
            AudiobookManifest.Track(href = "track1.wav", type = "audio/wav", duration = 600.0),
        ),
    )

    /**
     * R-49. Chapter one is playing; the chapter-two track will not open. The
     * coordinator had already moved its track, clock and chapter onto chapter
     * two, and nothing put them back — so the media session and the car named a
     * chapter with no audio, and the writer persisted it with an anchor into a
     * file that never loaded.
     */
    @Test
    fun aDeadTrackLeavesTheBookWhereItWas() = runTest {
        val subject = audiobook(
            backgroundScope, manifest(), files = mapOf("track0.wav" to Silence.file, "track1.wav" to missing()),
        )
        assertEquals(AudiobookCoordinator.MoveOutcome.LANDED, subject.start(atProgress = 0.1))
        val beforeTrack = subject.trackIndex
        val beforeTime = subject.bookTime
        val beforeChapter = subject.chapterIndex
        assertEquals(0, beforeTrack)

        subject.playChapter(1)

        assertEquals("the track moved onto a file that never opened", beforeTrack, subject.trackIndex)
        assertEquals("the chapter moved onto audio that never loaded", beforeChapter, subject.chapterIndex)
        assertTrue("the clock moved to ${subject.bookTime}", abs(subject.bookTime - beforeTime) < 0.001)
        assertNull("an anchor names a file that never loaded", subject.currentAnchor)
        assertFalse(subject.player.isPlaying)

        // And a press from here reloads the place the book is, rather than
        // claiming playback over nothing.
        subject.perform(PlaybackAction.PLAY, CommandMap())
        assertTrue(subject.player.isPlaying)
        assertEquals("track0.wav", subject.player.currentAudioHref)
        assertEquals(0, subject.trackIndex)
    }

    /**
     * R-11's half in this module: a start whose first track will not open says
     * so, rather than returning as if it had begun.
     */
    @Test
    fun aStartOverADeadTrackReportsIt() = runTest {
        val subject = audiobook(
            backgroundScope, manifest(), files = mapOf("track0.wav" to missing(), "track1.wav" to Silence.file),
        )

        assertEquals(AudiobookCoordinator.MoveOutcome.UNPLAYABLE, subject.start(atProgress = 0.0))
        assertFalse(subject.player.isPlaying)
        assertNull(subject.player.currentAudioHref)
        assertEquals("no place is not a start", AudiobookCoordinator.MoveOutcome.UNPLAYABLE, subject.start(Double.NaN))
    }
}
