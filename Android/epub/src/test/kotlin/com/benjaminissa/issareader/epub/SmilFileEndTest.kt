package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The end of an audio file hands on to the next file: what plays when an audio
 * file runs out is the first entry of the next file, whichever entry of this
 * one was playing.
 *
 * The end of a file used to ask for the entry after the one playing. In a run
 * the CTC aligner left out of time order, the clip playing at the end is the
 * one that ends last, which need not be the run's last entry, so the entry
 * after it was another clip of the same file: the advance seeked back into the
 * file, it played out and ended on the same clip, and it seeked back again, for
 * ever. The chapter never changed, so an end-of-chapter sleep timer never
 * fired. Ported from `SMILFileEndTests.swift`.
 */
class SmilFileEndTest {
    /**
     * ```
     *      0  a  a.mp3  0–5
     *      1  b  a.mp3  10–15   heard last, ends last
     *      2  c  a.mp3  5–10    listed last
     *      3  d  b.mp3  0–5
     * ```
     */
    private fun outOfOrder() = narration(
        Clip("a", "c.xhtml", "a.mp3", 0.0, 5.0, false),
        Clip("b", "c.xhtml", "a.mp3", 10.0, 15.0, false),
        Clip("c", "c.xhtml", "a.mp3", 5.0, 10.0, false),
        Clip("d", "d.xhtml", "b.mp3", 0.0, 5.0, false),
    )

    /** From any clip of an out-of-order file, the next file's first entry. */
    @Test
    fun outOfOrderFile() {
        val timeline = outOfOrder()
        val entries = timeline.entries
        for (index in 0..2) assertEquals("from entry $index", entries[3], timeline.entryFollowingFileOf(entries[index]))
    }

    /**
     * A pin, and the reason for the test above: the clip playing when the file
     * runs out is "b", and the entry after it is back in the same file.
     */
    @Test
    fun whyPositionIsNotEnough() {
        val timeline = outOfOrder()
        val entries = timeline.entries
        assertEquals(entries[1], timeline.entryInFile("a.mp3", at = 15.0))
        assertEquals(entries[2], timeline.entryFollowing(entries[1]))
        assertEquals(entries[1].audioHref, entries[2].audioHref)
    }

    /**
     * A file ending in a hole that spans the clips after it hands on to the next file.
     *
     * ```
     *      0  s0         a.mp3  0–5
     *      1  s0  hole   a.mp3  5–21   over audio the next two go on to read
     *      2  s1         a.mp3  10–15
     *      3  s2         a.mp3  15–20
     *      4  t0         b.mp3  0–5
     * ```
     */
    @Test
    fun holeOverTheLastClips() {
        val timeline = narration(
            Clip("s0", "c.xhtml", "a.mp3", 0.0, 5.0, false),
            Clip("s0", "c.xhtml", "a.mp3", 5.0, 21.0, true),
            Clip("s1", "c.xhtml", "a.mp3", 10.0, 15.0, false),
            Clip("s2", "c.xhtml", "a.mp3", 15.0, 20.0, false),
            Clip("t0", "d.xhtml", "b.mp3", 0.0, 5.0, false),
        )
        val entries = timeline.entries
        assertEquals("the hole ends last", entries[1], timeline.entryInFile("a.mp3", at = 25.0))
        assertEquals("and positionally is followed by s1", entries[2], timeline.entryFollowing(entries[1]))
        for (index in 0..3) assertEquals("from entry $index", entries[4], timeline.entryFollowingFileOf(entries[index]))
    }

    /**
     * Where the entry is the last of its file — every file end the two fixtures
     * have, v2's and v3's, including v3's out-of-order chapter three, which also
     * ends the book — the new question has the old answer.
     */
    @Test
    fun sameAnswerAtEveryFileEnd() {
        for (fixture in listOf("v2", "v3")) {
            val timeline = if (fixture == "v2") SmilV2GoldenTest.timeline() else SmilV3Test.timeline()
            val entries = timeline.entries
            val fileEnds = entries.indices.filter { index ->
                index == entries.size - 1 || entries[index + 1].audioHref != entries[index].audioHref
            }
            assertTrue(fixture, fileEnds.size >= 2)
            for (index in fileEnds) {
                assertEquals(
                    "$fixture at entry $index",
                    timeline.entryFollowing(entries[index]),
                    timeline.entryFollowingFileOf(entries[index]),
                )
            }
        }
    }

    /** From the middle of a file, the first entry of the next file. */
    @Test
    fun fromMidFile() {
        val v2 = SmilV2GoldenTest.timeline()
        assertEquals(v2.entries[4], v2.entryFollowingFileOf(v2.entries[0]))
        assertNull("track2 ends the book", v2.entryFollowingFileOf(v2.entries[4]))

        // v3: from ch01-s0 to the audio chapter, over the rest of track1; a
        // sentence continued into track2b goes on to it.
        val v3 = SmilV3Test.timeline()
        assertEquals(v3.entries[7], v3.entryFollowingFileOf(v3.entries[1]))
        assertEquals(v3.entries[11], v3.entryFollowingFileOf(v3.entries[10]))
        assertNull("track3 ends the book", v3.entryFollowingFileOf(v3.entries[13]))
    }

    /**
     * Each run of a file the spine plays twice hands on to what follows that
     * run. Which run is playing when the file ends is `entryInFile`'s answer,
     * and past the end that is always the last — see `entryFollowingFileOf`.
     */
    @Test
    fun repeatedFile() {
        val timeline = RepeatedAudioFileTest.timeline()
        val entries = timeline.entries
        assertEquals(entries[1], timeline.entryFollowingFileOf(entries[0]))
        assertEquals(entries[3], timeline.entryFollowingFileOf(entries[1]))
        assertEquals(entries[3], timeline.entryFollowingFileOf(entries[2]))
        assertNull(timeline.entryFollowingFileOf(entries[3]))
    }
}
