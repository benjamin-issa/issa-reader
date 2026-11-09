package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilTimeline
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `ReadalongV3Tests.swift` (`ReadalongV3Tests`), over the scripted
// engine.

/**
 * The read-along coordinator on a v3-aligned book.
 *
 * `readalong-v3.epub` is laid out in `SmilV3Test`'s header; the entries these
 * tests lean on are:
 *
 * ```
 *      1  ch01-s0                track1   6.5–10.75
 *      2  ch01-s0  after-hole    track1   10.75–17
 *      3  ch01-s1                track1   17–24.25
 *      5  ch01-s5                track1   30.65–35.75
 *      6  ch01-s5  after-hole    track1   35.75–44      the end of track1
 *      7  storyteller_audio_1-s0 bonus1   0–180         audio chapter, -a0
 *      8  storyteller_audio_1-s0 bonus2   0–150         audio chapter, -a1
 *      9  ch02-s0                track2a  0–5
 *     11  ch02-s1  -a1           track2b  0–3.5
 *     17  ch03-s4                track3   21–25
 *     18  ch03-s4  after-hole    track3   25–33         the end of the book
 * ```
 */
class ReadalongV3Test {
    /**
     * The loop. Chapter one's file ends in ch01-s5's after-hole, which names
     * ch01-s5's fragment. The clock ran into the hole without moving
     * `activeEntry` off the sentence, the end of the file then asked for the
     * entry after the sentence — the hole — and replayed it; the next end
     * resolved the hole back to the sentence and found the hole again, for ever.
     * What follows the hole is the audio chapter, in the next file.
     */
    @Test
    fun aFileEndingInAHoleAdvances() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            val entries = readalong.timeline.entries
            val sentence = entries[5]
            val hole = entries[6]
            val interlude = entries[7]
            val interludeContinued = entries[8]
            val chapterTwo = entries[9]
            check(hole.isAudioOnly && hole.fragmentId == sentence.fragmentId)
            check(interlude.audioHref == "OEBPS/Audio/bonus1.mp3")

            // Prepared rather than played, so nothing runs on after the advance:
            // `isPlaying` stays false, and the advance moves without resuming.
            assertTrue(subject.prepare(sentence))
            val tick = detachClock(subject.player)
            var endings = 0
            subject.onChapterChangeObserved = { endings += 1 }

            // The clock runs on from the sentence into the hole that ends the file.
            tick((hole.start + hole.end) / 2)
            assertEquals(hole, subject.activeEntry)

            subject.player.onFinishedFile?.invoke()
            val advanced = settle { subject.activeEntry == interlude && subject.movesInFlight == 0 }
            assertTrue("the end of the file did not move on to the audio chapter", advanced)
            assertEquals("and it must not replay the hole", interlude, subject.activeEntry)
            assertEquals(interlude.audioHref, subject.player.currentAudioHref)
            assertEquals("chapter one ended, once", 1, endings)

            // And on through the audio chapter's second file, which is no new
            // chapter, and out into chapter two, which is.
            subject.player.onFinishedFile?.invoke()
            assertTrue(settle { subject.activeEntry == interludeContinued && subject.movesInFlight == 0 })
            assertEquals(interludeContinued.audioHref, subject.player.currentAudioHref)
            assertEquals("the audio chapter's own second file is not a chapter ending", 1, endings)

            subject.player.onFinishedFile?.invoke()
            assertTrue(settle { endings == 2 })
            assertEquals(chapterTwo, subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * v2 paused at the end of the book, with those seconds folded into the last
     * sentence. The hole that holds them now must end the same way.
     */
    @Test
    fun theClosingHolePauses() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            val entries = readalong.timeline.entries
            val last = entries[17]
            val hole = entries[18]
            check(hole == entries.last() && hole.isAudioOnly)

            subject.play(last)
            // Silenced and frozen, not paused: `isPlaying` is what is under test.
            val tick = detachClock(subject.player)
            subject.player.rate = 0f
            check(subject.player.isPlaying)

            tick((hole.start + hole.end) / 2)
            assertEquals(hole, subject.activeEntry)

            subject.player.onFinishedFile?.invoke()
            assertTrue("the end of the book did not pause", settle { !subject.player.isPlaying })
            assertEquals("and nothing replayed", hole, subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The hole names the sentence it follows, and v2 lit that sentence for these
     * same seconds. So the entry moves — the anchor and the skip buttons measure
     * from it — and the page does not hear about it.
     */
    @Test
    fun tickingIntoAnAfterHole() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            val entries = readalong.timeline.entries
            val sentence = entries[1]
            val hole = entries[2]
            val next = entries[3]

            assertTrue(subject.prepare(sentence))
            val tick = detachClock(subject.player)
            val fragments = ArrayList<String>()
            val chapters = ArrayList<String>()
            var endings = 0
            subject.onFragmentChange = { fragments.add(it) }
            subject.onChapterChange = { chapters.add(it) }
            subject.onChapterChangeObserved = { endings += 1 }

            // The player's own clock goes where the tick says, as it would.
            val inside = hole.start + 2
            subject.player.seek(inside)
            tick(inside)

            assertEquals(hole, subject.activeEntry)
            assertEquals(sentence.fragmentId, subject.activeFragmentId)
            assertTrue("the highlight is already on the sentence the hole names", fragments.isEmpty())
            assertTrue(chapters.isEmpty())
            assertEquals(0, endings)
            val anchor = checkNotNull(subject.currentAnchor)
            assertEquals(hole.audioHref, anchor.audioHref)
            assertTrue(
                "clamped into the sentence, the anchor read ${anchor.offset}",
                anchor.offset > hole.start && anchor.offset < hole.end,
            )
            assertEquals(inside, anchor.offset, 0.001)

            // Out of the hole into the next sentence is a real change.
            tick(next.start + 1)
            assertEquals(next, subject.activeEntry)
            assertEquals(listOf(next.fragmentId), fragments)
        } finally {
            readalong.delete()
        }
    }

    /** Next sentence from a hole is the next sentence, not the one the hole belongs to. */
    @Test
    fun nextSentenceFromAHole() = runTest {
        val readalong = makeReadalong(backgroundScope, v3 = true)
        val subject = readalong.subject
        try {
            val entries = readalong.timeline.entries
            val map = CommandMap()
            // The command plays from where it lands. Neither the clock nor an end
            // of file may move the entry between the command and the look at
            // where it went.
            subject.player.onTimeUpdate = null
            subject.player.onFinishedFile = null

            assertTrue(subject.prepare(entries[2]))
            subject.perform(PlaybackAction.NEXT_SENTENCE, map)
            assertEquals(entries[3], subject.activeEntry)

            // From the hole that ends chapter one, over the audio chapter.
            assertTrue(subject.prepare(entries[6]))
            subject.perform(PlaybackAction.NEXT_SENTENCE, map)
            assertEquals(entries[9], subject.activeEntry)

            // And back from a continuation to the sentence before the one it
            // continues.
            assertTrue(subject.prepare(entries[11]))
            subject.perform(PlaybackAction.PREVIOUS_SENTENCE, map)
            assertEquals(entries[9], subject.activeEntry)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The car and the lock screen play the same chunks through the audiobook
     * engine. An audio chapter has files of its own and a place in the contents,
     * so it has tracks and a chapter there too.
     */
    @Test
    fun chunkManifestHasTheAudioChapter() {
        val (timeline, epubPackage) = readalongV3Timeline()
        val directory = scratchDirectory("issa-readalong-v3-manifest")
        try {
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "readalong-v3-manifest", directory)

            val result = ChunkManifest.make(timeline, epubPackage, files, emptyMap(), null)

            assertEquals(
                listOf(
                    "OEBPS/Audio/track1.mp3", "OEBPS/Audio/bonus1.mp3", "OEBPS/Audio/bonus2.mp3",
                    "OEBPS/Audio/track2a.mp3", "OEBPS/Audio/track2b.mp3", "OEBPS/Audio/track3.mp3",
                ),
                result.manifest.readingOrder.map { it.href },
            )
            assertEquals(
                listOf("Chapter One", "After Chapter One", "Chapter Two", "Chapter Three"),
                result.chapters.map { it.title },
            )
            val interlude = result.chapters.first { it.title == "After Chapter One" }
            assertEquals(1, interlude.trackIndex)
            assertEquals(0.0, interlude.offset, 0.0)
        } finally {
            directory.deleteRecursively()
        }
    }
}

// Ported from `ReadalongV3Tests.swift` (`ReadalongV3ShapesTests`).

/**
 * The read-along on the other shapes Storyteller 3 writes, which the generated
 * fixture does not reach: word granularity, an audio chapter that opens in the
 * middle of a text chapter's file, and a sentence whose after-holes run through
 * three files. The timelines are stated by hand and played over the v3
 * fixture's own audio files, which is all the player needs of them.
 */
class ReadalongV3ShapesTest {
    /**
     * The loop, one granularity down. The holes name the sentence and the words
     * between them do not, so resolved through its key the after-hole was the
     * before-hole, and the end of the file moved to the sentence's first word
     * and played the sentence and its music again, for ever.
     */
    @Test
    fun wordGranularFileEndingInAHole() = runTest {
        // Each word carries its sentence, as the parser writes it for a
        // `text-range-small` seq; the holes name the sentence itself and carry
        // none.
        val timeline = narration(
            Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 0.0, 6.0, true, null),
            Clip("ch01-s0-w0", Shapes.chapterOne, Shapes.track1, 6.0, 7.0, false, "ch01-s0"),
            Clip("ch01-s0-w1", Shapes.chapterOne, Shapes.track1, 7.0, 8.0, false, "ch01-s0"),
            Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 8.0, 20.0, true, null),
            Clip("ch01-s1-w0", Shapes.chapterOne, Shapes.track2, 0.0, 2.0, false, "ch01-s1"),
            Clip("ch01-s1-w1", Shapes.chapterOne, Shapes.track2, 2.0, 5.0, false, "ch01-s1"),
        )
        check(timeline.entries[1].sentenceId == "ch01-s0")
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[2]))
            val tick = detachClock(subject.player)
            val fragments = ArrayList<String>()
            var endings = 0
            subject.onFragmentChange = { fragments.add(it) }
            subject.onChapterChangeObserved = { endings += 1 }

            // From the last word into the music after it: the highlight goes back
            // out to the whole sentence, as the hole names it.
            tick(14.0)
            assertEquals(entries[3], subject.activeEntry)
            assertEquals(listOf("ch01-s0"), fragments)

            subject.player.onFinishedFile?.invoke()
            val advanced = settle { subject.activeEntry == entries[4] && subject.movesInFlight == 0 }
            assertTrue("the end of the file went back into the sentence", advanced)
            assertEquals(Shapes.track2, subject.player.currentAudioHref)
            assertEquals("the same chapter carries on", 0, endings)
        } finally {
            readalong.delete()
        }
    }

    /**
     * ```
     *      0  ch01-s0                 track1  0–30.65
     *      1  ch01-s5                 track1  30.65–35.75
     *      2  storyteller_audio_1-a0  track1  35.75–44   the interlude opens mid-file
     *      3  storyteller_audio_1-a1  bonus1  0–180
     *      4  storyteller_audio_1-a2  bonus2  0–150
     *      5  ch02-s0                 track2a 0–5
     * ```
     *
     * What the aligner plans when chapter one's file ends in a few seconds of
     * silence and two untitled tracks follow: one run of boundary holes, over
     * five minutes long, so one audio chapter, starting where the last sentence
     * of chapter one stops.
     */
    private fun untitledTracks(): SmilTimeline = narration(
        Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 0.0, 30.65),
        Clip("ch01-s5", Shapes.chapterOne, Shapes.track1, 30.65, 35.75),
        Clip("storyteller_audio_1-s0", Shapes.interlude, Shapes.track1, 35.75, 44.0, true),
        Clip("storyteller_audio_1-s0", Shapes.interlude, Shapes.bonus1, 0.0, 180.0, true),
        Clip("storyteller_audio_1-s0", Shapes.interlude, Shapes.bonus2, 0.0, 150.0, true),
        Clip("ch02-s0", Shapes.chapterTwo, Shapes.track2, 0.0, 5.0),
    )

    /**
     * No file boundary to announce it, so the clock does: chapter one has ended,
     * the page turns to the audio chapter's heading, once.
     */
    @Test
    fun midFileInterlude() = runTest {
        val timeline = untitledTracks()
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[1]))
            val tick = detachClock(subject.player)
            val fragments = ArrayList<String>()
            val chapters = ArrayList<String>()
            var endings = 0
            subject.onFragmentChange = { fragments.add(it) }
            subject.onChapterChange = { chapters.add(it) }
            subject.onChapterChangeObserved = { endings += 1 }

            tick(40.0)
            tick(41.0)
            assertEquals(entries[2], subject.activeEntry)
            assertEquals(listOf("storyteller_audio_1-s0"), fragments)
            assertEquals(listOf(Shapes.interlude), chapters)
            assertEquals(1, endings)

            // Its own next two files are the same chapter; the file after is not.
            subject.player.onFinishedFile?.invoke()
            assertTrue(settle { subject.activeEntry == entries[3] && subject.movesInFlight == 0 })
            subject.player.onFinishedFile?.invoke()
            assertTrue(settle { subject.activeEntry == entries[4] && subject.movesInFlight == 0 })
            assertEquals(1, endings)
            assertEquals(listOf(Shapes.interlude), chapters)

            subject.player.onFinishedFile?.invoke()
            assertTrue(settle { subject.activeEntry == entries[5] && subject.movesInFlight == 0 })
            assertEquals(2, endings)
            assertEquals(listOf(Shapes.interlude, Shapes.chapterTwo), chapters)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The car's chapter list for the same book: the audio chapter begins in
     * chapter one's track, where chapter one's narration stops.
     */
    @Test
    fun midFileInterludeChapter() {
        val (_, epubPackage) = readalongV3Timeline()
        val chapters = ChunkManifest.chapters(
            untitledTracks(), epubPackage, listOf(Shapes.track1, Shapes.bonus1, Shapes.bonus2, Shapes.track2),
        )
        assertEquals(
            listOf(
                AudiobookChapter("Chapter One", trackIndex = 0, offset = 0.0),
                AudiobookChapter("After Chapter One", trackIndex = 0, offset = 35.75),
                AudiobookChapter("Chapter Two", trackIndex = 3, offset = 0.0),
            ),
            chapters,
        )
    }

    /**
     * What the aligner plans for the same audio when the bonus tracks are
     * titled: each is a run of its own, none reaches five minutes, and the last
     * sentence of chapter one keeps an after-hole in all three files. Every one
     * of them names that sentence, and every file ends in one.
     */
    @Test
    fun afterHolesInThreeFiles() = runTest {
        val timeline = narration(
            Clip("ch01-s5", Shapes.chapterOne, Shapes.track1, 30.65, 35.75),
            Clip("ch01-s5", Shapes.chapterOne, Shapes.track1, 35.75, 44.0, true),
            Clip("ch01-s5", Shapes.chapterOne, Shapes.bonus1, 0.0, 180.0, true),
            Clip("ch01-s5", Shapes.chapterOne, Shapes.bonus2, 0.0, 150.0, true),
            Clip("ch02-s0", Shapes.chapterTwo, Shapes.track2, 0.0, 5.0),
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[0]))
            val tick = detachClock(subject.player)
            val fragments = ArrayList<String>()
            var endings = 0
            subject.onFragmentChange = { fragments.add(it) }
            subject.onChapterChangeObserved = { endings += 1 }

            tick(40.0)
            assertEquals(entries[1], subject.activeEntry)
            assertTrue(fragments.isEmpty())

            for (index in 2..4) {
                subject.player.onFinishedFile?.invoke()
                val advanced = settle { subject.activeEntry == entries[index] && subject.movesInFlight == 0 }
                assertTrue("the end of the file before entry $index did not reach it", advanced)
                assertEquals(entries[index].audioHref, subject.player.currentAudioHref)
            }
            assertEquals("chapter one ended once, after its last hole", 1, endings)
        } finally {
            readalong.delete()
        }
    }

    /**
     * The overlap-to-file-end shape a CTC back-jump leaves after the aligner
     * collapses its ranges: the last clip in the file starts *before* the one
     * read just ahead of it and runs to the file's end. At 40 s the clip playing
     * is the later entry, whose start is earlier than the active one's. The
     * jitter guard read that as a clock sampled a hair early and kept the stale
     * entry, so the end of the file advanced from it — into the out-of-order
     * clip, back in the same file.
     */
    @Test
    fun outOfOrderClipIsNotJitter() = runTest {
        val timeline = narration(
            Clip("ch01-s0", Shapes.chapterOne, Shapes.track1, 20.0, 35.0),
            Clip("ch01-s1", Shapes.chapterOne, Shapes.track1, 5.0, 44.0),
            Clip("ch02-s0", Shapes.chapterTwo, Shapes.track2, 0.0, 5.0),
        )
        val readalong = makeReadalong(backgroundScope, timeline)
        val subject = readalong.subject
        try {
            val entries = timeline.entries

            assertTrue(subject.prepare(entries[0]))
            val tick = detachClock(subject.player)

            tick(40.0)
            assertEquals("the clip playing at 40 s is the out-of-order one", entries[1], subject.activeEntry)

            subject.player.onFinishedFile?.invoke()
            val advanced = settle { subject.activeEntry == entries[2] && subject.movesInFlight == 0 }
            assertTrue("the end of the file went back into the same file", advanced)
            assertEquals(Shapes.track2, subject.player.currentAudioHref)
        } finally {
            readalong.delete()
        }
    }
}
