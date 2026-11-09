package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilEntry
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `ReadalongSeekOffsetTests.swift`, over the scripted engine.

/**
 * A scrub or a skip lands on the time it names, inside whichever entry holds it
 * — not at the start of that entry.
 *
 * The entry's start was all a seek kept. On a v2 book that put a skip at the
 * start of the sentence it fell in, a few seconds early. On a v3 book a hole or
 * an audio chapter is a single entry minutes long, so a scrub inside one went
 * back to its start and a thirty-second skip forward from its middle went
 * backwards; and every such landing was saved as a position the listener had
 * chosen.
 *
 * The v3 fixture's entries these lean on, with their place on the book's
 * timeline:
 *
 * ```
 *      3  ch01-s1                track1   17–24.25   book 17–24.25
 *      7  storyteller_audio_1-s0 bonus1   0–180      book 43.999–223.999
 *      8  storyteller_audio_1-s0 bonus2   0–150      book 223.999–373.999
 *      9  ch02-s0                track2a  0–5        book 373.999–378.999
 *     18  ch03-s4  after-hole    track3   25–33      the end of the book
 * ```
 *
 * The clock and the end of the file are taken away, so the player's clock is
 * exactly where the coordinator's seek put it.
 */
class ReadalongSeekOffsetTest {
    private fun make(scope: CoroutineScope, v2: Boolean = false): Readalong {
        val readalong = makeReadalong(scope, v3 = !v2)
        readalong.subject.player.onTimeUpdate = null
        readalong.subject.player.onFinishedFile = null
        return readalong
    }

    /** Where an entry starts on the book's timeline. */
    private fun bookStart(entry: SmilEntry): Double = entry.cumulativeEnd - entry.duration

    /** A scrub into the middle of an audio chapter lands in its middle. */
    @Test
    fun scrubIntoALongEntry() = runTest {
        val readalong = make(backgroundScope)
        val subject = readalong.subject
        try {
            val total = readalong.timeline.totalDuration
            val interlude = readalong.timeline.entries[7]
            val target = bookStart(interlude) + 60

            subject.seekToBookProgress(target / total)
            assertTrue("a minute into bonus1", abs(subject.player.currentTime - 60) < 0.01)
            assertEquals(interlude, subject.activeEntry)
            assertEquals(interlude.audioHref, subject.player.currentAudioHref)
            assertTrue(abs(subject.bookProgress * total - target) < 0.01)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The finding: from a minute into the audio chapter, +30 s resolved to the
     * same entry and moved to its start — backwards — and the next +30 did it
     * again.
     */
    @Test
    fun skipInsideALongEntry() = runTest {
        val readalong = make(backgroundScope)
        val subject = readalong.subject
        try {
            val total = readalong.timeline.totalDuration
            val interlude = readalong.timeline.entries[7]
            val start = bookStart(interlude)

            subject.seekToBookProgress((start + 60) / total)
            subject.skipBook(30.0)
            assertTrue(abs(subject.player.currentTime - 90) < 0.01)
            assertTrue(abs(subject.bookProgress * total - (start + 90)) < 0.01)

            subject.skipBook(30.0)
            assertTrue("and on again, not back", abs(subject.player.currentTime - 120) < 0.01)
            assertTrue(abs(subject.bookProgress * total - (start + 120)) < 0.01)
            assertEquals(interlude, subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * Back across a file boundary into the audio chapter's second file: exactly
     * fifteen seconds back, which is 137 s into bonus2.
     */
    @Test
    fun skipBackAcrossAFile() = runTest {
        val readalong = make(backgroundScope)
        val subject = readalong.subject
        try {
            val total = readalong.timeline.totalDuration
            val entries = readalong.timeline.entries
            val chapterTwo = entries[9]
            val interludeContinued = entries[8]

            assertTrue(subject.prepare(chapterTwo))
            subject.player.seek(2.0)
            subject.skipBook(-15.0)
            assertTrue(abs(subject.player.currentTime - 137) < 0.01)
            assertEquals(interludeContinued, subject.activeEntry)
            assertEquals(interludeContinued.audioHref, subject.player.currentAudioHref)
            assertTrue(abs(subject.bookProgress * total - (bookStart(chapterTwo) + 2 - 15)) < 0.01)
        } finally {
            readalong.delete()
        }
    }

    /**
     * A pin: a time exactly on a boundary belongs to the entry that starts there,
     * and lands on its start, as it always did.
     */
    @Test
    fun scrubOntoABoundary() = runTest {
        val readalong = make(backgroundScope)
        val subject = readalong.subject
        try {
            val total = readalong.timeline.totalDuration
            val sentence = readalong.timeline.entries[3]
            val boundary = bookStart(sentence)
            // The fraction whose time is the boundary itself, not a rounding of
            // it a hair early.
            var progress = boundary / total
            while (total * progress < boundary) progress = Math.nextUp(progress)

            subject.seekToBookProgress(progress)
            assertEquals(sentence.start, subject.player.currentTime, 0.0)
            assertEquals(sentence, subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The far end of the bar is the end of the last entry, short of it by a hair
     * so that the file still plays out and ends the book.
     */
    @Test
    fun scrubToTheEnd() = runTest {
        val readalong = make(backgroundScope)
        val subject = readalong.subject
        try {
            val last = readalong.timeline.entries.last()

            subject.seekToBookProgress(1.0)
            val landed = subject.player.currentTime
            assertTrue(abs(landed - (last.end - ReadalongCoordinator.END_OF_ENTRY_MARGIN)) < 0.001)
            assertTrue(landed < last.end)
            assertEquals(last, subject.activeEntry)
            assertTrue(subject.bookProgress > 0.999 && subject.bookProgress < 1)
        } finally {
            readalong.delete()
        }
    }

    /**
     * v2 was wrong here too, by a few seconds: a skip landed at the start of the
     * sentence it fell in. Now a scrub to a time reads back as that time, as the
     * audiobook engine's does.
     */
    @Test
    fun v2RoundTrip() = runTest {
        for (target in listOf(0.0, 5.0, 15.3, -1.0)) {
            val readalong = make(backgroundScope, v2 = true)
            val subject = readalong.subject
            try {
                val total = readalong.timeline.totalDuration
                val time = if (target < 0) total + target else target

                subject.seekToBookProgress(time / total)
                val entry = checkNotNull(subject.activeEntry)
                assertTrue(
                    "$target",
                    abs(subject.player.currentTime - (entry.start + time - bookStart(entry))) < 0.01,
                )
                assertTrue("$target", abs(subject.bookProgress * total - time) < 0.01)
            } finally {
                readalong.delete()
            }
        }
    }

    /** On a v2 book a skip back moves by exactly the skip. */
    @Test
    fun v2SkipBack() = runTest {
        val readalong = make(backgroundScope, v2 = true)
        val subject = readalong.subject
        try {
            val total = readalong.timeline.totalDuration
            val first = readalong.timeline.entries[0]

            subject.seekToBookProgress(15.3 / total)
            subject.skipBook(-15.0)
            assertTrue(abs(subject.player.currentTime - (first.start + 0.3)) < 0.01)
            assertEquals(first, subject.activeEntry)
            assertTrue(abs(subject.bookProgress * total - 0.3) < 0.01)
        } finally {
            readalong.delete()
        }
    }
}
