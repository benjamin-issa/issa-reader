package com.benjaminissa.issareader.playback

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `ReadalongFileEndTests.swift`, over the scripted engine.

/**
 * The end of an audio file whose clips the CTC aligner left out of time order,
 * played by the coordinator over the v3 fixture's own files.
 *
 * The clip playing when such a file runs out is the one that ends last, and it
 * need not be the file's last entry. The advance asked for the entry after it,
 * got another clip of the same file, seeked back into the file, and the file
 * ended on the same clip again — for ever, and without a chapter ever ending,
 * so an end-of-chapter sleep timer never paused it.
 */
class ReadalongFileEndTest {
    private val chapterThree = "OEBPS/ch03.xhtml"
    private val track3 = "OEBPS/Audio/track3.mp3"

    /** The last two rows of each shape below: the next two files. */
    private val nextFiles = listOf(
        Clip("ch02-s0", Shapes.chapterTwo, Shapes.track2, 0.0, 5.0),
        Clip("ch03-s0", chapterThree, track3, 0.0, 4.0),
    )

    /**
     * Takes the clock off the player and counts chapter endings, the way the
     * shapes tests do, so the test says exactly where the audio is.
     */
    private fun take(subject: ReadalongCoordinator): Pair<(Double) -> Unit, () -> Int> {
        val tick = detachClock(subject.player)
        var endings = 0
        subject.onChapterChangeObserved = { endings += 1 }
        return tick to { endings }
    }

    /**
     * ```
     *      0  ch01-s0  track1   0–5
     *      1  ch01-s1  track1   10–44   heard last, runs to the end of the file
     *      2  ch01-s2  track1   5–10    listed last
     *      3  ch02-s0  track2a  0–5
     *      4  ch03-s0  track3   0–4
     * ```
     */
    @Test
    fun outOfOrderFileEnds() = runTest {
        val timeline = narration(
            listOf(
                Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 0.0, 5.0),
                Clip("ch01-s1", Shapes.chapterOne, Shapes.track1, 10.0, 44.0),
                Clip("ch01-s2", Shapes.chapterOne, Shapes.track1, 5.0, 10.0),
            ) + nextFiles,
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            // Prepared rather than played, so no end of file joins in.
            assertTrue(subject.prepare(entries[0]))
            val (tick, endings) = take(subject)
            tick(40.0)
            assertEquals(entries[1], subject.activeEntry)

            subject.player.onFinishedFile?.invoke()
            val advanced = settle { subject.activeEntry == entries[3] && subject.movesInFlight == 0 }
            assertTrue("the end of the file went back into the same file", advanced)
            assertEquals(entries[3], subject.activeEntry)
            assertEquals(Shapes.track2, subject.player.currentAudioHref)
            assertEquals("chapter one ended, once", 1, endings())
        } finally {
            readalong.delete()
        }
    }

    /**
     * ```
     *      0  ch01-s0             track1   0–5
     *      1  ch01-s0  hole       track1   5–21    over the next two, to the end
     *      2  ch01-s1             track1   10–15
     *      3  ch01-s2             track1   15–20
     *      4  ch02-s0             track2a  0–5
     *      5  ch03-s0             track3   0–4
     * ```
     */
    @Test
    fun holeOverTheLastClipsEnds() = runTest {
        val timeline = narration(
            listOf(
                Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 0.0, 5.0),
                Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 5.0, 21.0, true),
                Clip("ch01-s1", Shapes.chapterOne, Shapes.track1, 10.0, 15.0),
                Clip("ch01-s2", Shapes.chapterOne, Shapes.track1, 15.0, 20.0),
            ) + nextFiles,
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[0]))
            val (tick, endings) = take(subject)
            tick(20.5)
            assertEquals("only the hole is still playing at 20.5 s", entries[1], subject.activeEntry)

            subject.player.onFinishedFile?.invoke()
            val advanced = settle { subject.activeEntry == entries[4] && subject.movesInFlight == 0 }
            assertTrue("the end of the file went back into the same file", advanced)
            assertEquals(Shapes.track2, subject.player.currentAudioHref)
            assertEquals(1, endings())
        } finally {
            readalong.delete()
        }
    }

    /**
     * The end of track1 reaches the coordinator just as the listener moves to
     * chapter two, and the advance it schedules runs at the move's first
     * suspension, with `activeEntry` already on chapter two. Answered, it
     * advanced from there — past the rest of chapter two, into chapter three,
     * and reported chapter two as ended.
     */
    @Test
    fun aStaleEndingIsDropped() = runTest {
        val timeline = narration(
            listOf(
                Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 0.0, 5.0),
                Clip("ch01-s1", Shapes.chapterOne, Shapes.track1, 5.0, 44.0),
            ) + nextFiles,
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[0]))
            val (_, endings) = take(subject)

            // Queued before the move begins, so it runs at the move's own
            // suspension inside the engine.
            subject.player.onFinishedFile?.invoke()
            assertTrue(subject.prepare(entries[2]))
            assertTrue(settle { subject.movesInFlight == 0 })

            assertEquals("the move the listener made is where the book is", entries[2], subject.activeEntry)
            assertEquals(Shapes.track2, subject.player.currentAudioHref)
            assertEquals("a chapter the listener moved into did not end", 0, endings())
        } finally {
            readalong.delete()
        }
    }
}
