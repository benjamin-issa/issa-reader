package com.benjaminissa.issareader.epub

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `SMILTimelineTests.swift`: one class per Swift suite.

/**
 * Built against a fixture that reproduces Storyteller's aligner output,
 * including the two things real output contains that break naive readers: a
 * ~1 ms filler entry, and a gap in sentence-id numbering left by a footnote.
 */
class SmilTimelineTest {
    companion object {
        fun book(): EpubPackage = openFixture("readalong")
    }

    @Test
    fun readsOverlayMetadata() {
        val book = book()
        // Leading hyphen. The spec's usual example has none, so a reader that
        // assumes the default highlights nothing.
        assertEquals("-epub-media-overlay-active", book.metadata.mediaActiveClass)
        assertNotNull(book.metadata.mediaDuration)
        assertTrue(book.spine.all { it.mediaOverlayId != null })
    }

    /** Builds a gapless book timeline across chapters. */
    @Test
    fun buildsTimeline() {
        val timeline = SmilParser.timeline(book())
        assertFalse(timeline.isEmpty)

        // The 1 ms filler entry must not appear.
        assertFalse(timeline.entries.any { it.fragmentId == "ch01-s2" })
        assertTrue(timeline.entries.all { it.duration >= SmilParser.minimumMeaningfulDuration })

        // cumulativeEnd is a running total of clip durations, so it increases
        // strictly and spans chapters — it is not an offset into any one file.
        var previous = 0.0
        for (entry in timeline.entries) {
            assertTrue(entry.cumulativeEnd > previous)
            previous = entry.cumulativeEnd
        }
        assertTrue(abs(timeline.totalDuration - previous) < 0.0001)
    }

    /** Sentence ids are not contiguous, and that is fine. */
    @Test
    fun handlesNonContiguousIds() {
        val timeline = SmilParser.timeline(book())
        val chapterOne = timeline.entries.filter { it.fragmentId.startsWith("ch01") }.map { it.fragmentId }
        // s2 is dropped as filler and s4 lives in the footnotes section.
        assertEquals(listOf("ch01-s0", "ch01-s1", "ch01-s3", "ch01-s5"), chapterOne)
    }

    /** A time on a boundary belongs to the entry that starts there. */
    @Test
    fun boundaryGoesForward() {
        val timeline = SmilParser.timeline(book())
        val first = timeline.entries.first()
        // Exactly at the end of entry 0 should select entry 1, not entry 0.
        val atBoundary = timeline.entryAtBookTime(first.cumulativeEnd)!!
        assertEquals(timeline.entries[1].fragmentId, atBoundary.fragmentId)

        val inside = timeline.entryAtBookTime(first.cumulativeEnd - 0.001)!!
        assertEquals(first.fragmentId, inside.fragmentId)
    }

    /** Looks up every entry by its own midpoint. */
    @Test
    fun lookupIsExhaustive() {
        val timeline = SmilParser.timeline(book())
        for (entry in timeline.entries) {
            val midpoint = entry.cumulativeEnd - entry.duration / 2
            val found = timeline.entryAtBookTime(midpoint)!!
            assertEquals("midpoint of ${entry.fragmentId} resolved to ${found.fragmentId}", entry.fragmentId, found.fragmentId)
        }
    }

    /** Seeking from a fragment id round-trips. */
    @Test
    fun seekRoundTrips() {
        val timeline = SmilParser.timeline(book())
        for (entry in timeline.entries) {
            val time = timeline.bookTimeForFragment(entry.fragmentId)!!
            // Landing exactly on the start boundary must select this entry.
            val found = timeline.entryAtBookTime(time)!!
            assertEquals(entry.fragmentId, found.fragmentId)
        }
    }

    /** Progression spans the whole book, across chapters. */
    @Test
    fun progression() {
        val timeline = SmilParser.timeline(book())
        assertEquals(0.0, timeline.progressionAtBookTime(0.0), 0.0)
        assertEquals(1.0, timeline.progressionAtBookTime(timeline.totalDuration), 0.0)
        // Clamped, never out of range.
        assertEquals(0.0, timeline.progressionAtBookTime(-5.0), 0.0)
        assertEquals(1.0, timeline.progressionAtBookTime(timeline.totalDuration * 2), 0.0)
    }

    /** Entries carry the chapter and audio file they belong to. */
    @Test
    fun entriesCarryHrefs() {
        val timeline = SmilParser.timeline(book())
        val chapterOne = timeline.entriesInDocument("OEBPS/ch01.xhtml")
        assertTrue(chapterOne.isNotEmpty())
        assertTrue(chapterOne.all { it.audioHref == "OEBPS/Audio/track1.mp3" })

        val chapterTwo = timeline.entriesInDocument("OEBPS/ch02.xhtml")
        assertTrue(chapterTwo.all { it.audioHref == "OEBPS/Audio/track2.mp3" })
        // A second chapter restarts its clips at zero within its own file, while
        // the book timeline keeps climbing.
        assertEquals(0.0, chapterTwo.firstOrNull()?.start)
        assertTrue((chapterTwo.firstOrNull()?.cumulativeEnd ?: 0.0) > (chapterOne.lastOrNull()?.cumulativeEnd ?: 0.0))
    }

    @Test
    fun unknownFragment() {
        val timeline = SmilParser.timeline(book())
        assertNull(timeline.bookTimeForFragment("nope-s99"))
        assertNull(timeline.entryForFragment("nope-s99"))
    }

    /**
     * An anchor's offset can predate the file's first clip — an aligner that
     * starts a chapter a moment in, an offset rounded to zero, a differently
     * transcoded copy. `entryInFile` answers nothing there, which is the hole
     * that sent a listener resuming from the car to chapter one.
     */
    @Test
    fun anOffsetBeforeTheFirstClipStillNamesTheFile() {
        val timeline = SmilParser.timeline(book())
        assertNull("the per-tick lookup is right to answer nothing here", timeline.entryInFile("OEBPS/Audio/track1.mp3", at = -0.5))
        assertEquals("ch01-s0", timeline.firstEntryInFile("OEBPS/Audio/track1.mp3")?.fragmentId)
        // A file this book's overlay has never heard of is still nothing: the
        // fallback names a file, it does not invent one.
        assertNull(timeline.firstEntryInFile("The Outsider.mp3"))
    }

    // Where narration may begin

    /**
     * The lookup that replaced `entries.first()` as the fallback when a reader
     * presses play and the visible page carries no narrated sentence. It must
     * only ever look *forward*: answering with the start of the book is what
     * read a part-read novel back from page one and then saved that position.
     */
    @Test
    fun findsNarrationAtOrAfterChapter() {
        val book = book()
        val timeline = SmilParser.timeline(book)
        val hrefs = book.spine.map { it.href }

        // From the first chapter, the answer is the first entry of the book.
        val fromStart = timeline.firstEntryInAnyOf(hrefs)!!
        assertEquals(timeline.entries.first().fragmentId, fromStart.fragmentId)

        // From the second chapter onwards it must NOT be the first entry.
        val fromLater = timeline.firstEntryInAnyOf(hrefs.drop(1))!!
        assertNotEquals(fromStart.textHref, fromLater.textHref)
        assertNotEquals(
            "looking forward from chapter two must never answer with chapter one",
            timeline.entries.first().fragmentId,
            fromLater.fragmentId,
        )
    }

    /** Returns nothing when no document ahead is narrated. */
    @Test
    fun findsNothingAhead() {
        val timeline = SmilParser.timeline(book())
        assertNull(timeline.firstEntryInAnyOf(listOf("OEBPS/not-a-real-document.xhtml")))
        assertNull(timeline.firstEntryInAnyOf(emptyList()))
    }

    /** Answers with the earliest of the documents offered, in spine order. */
    @Test
    fun answersInSpineOrder() {
        val book = book()
        val timeline = SmilParser.timeline(book)
        val hrefs = book.spine.map { it.href }
        // Offered in reverse, the answer is still the one that comes first in
        // the book — the set is a filter, not an ordering.
        val reversed = timeline.firstEntryInAnyOf(hrefs.reversed())!!
        assertEquals(timeline.entries.first().fragmentId, reversed.fragmentId)
    }
}

/**
 * A file referenced from more than one place in the spine, with a different
 * file's entries in between — an intro or outro clip shared across chapters.
 *
 * `entryInFile` used to bound its search with a *widened* range spanning both
 * runs, which included whatever fell between them. Since clip times restart
 * near zero per file, a `time` that legitimately belongs to the interloping
 * file could match — silently returning a different file's sentence for the
 * file actually asked about, while the correct audio kept playing.
 */
class RepeatedAudioFileTest {
    companion object {
        /**
         * intro.mp3 plays 0-2s, then chapter1.mp3 plays 0-6s while intro.mp3 is
         * silent, then intro.mp3 resumes at 5-7s. Time 3 is squarely inside
         * chapter1.mp3's second sentence and inside the *gap* between
         * intro.mp3's two runs — nowhere in intro.mp3 at all.
         */
        fun timeline() = SmilTimeline(
            listOf(
                SmilEntry("intro-s0", "intro.xhtml", "intro.mp3", start = 0.0, end = 2.0, cumulativeEnd = 2.0),
                SmilEntry("ch1-s0", "ch1.xhtml", "chapter1.mp3", start = 0.0, end = 3.0, cumulativeEnd = 5.0),
                SmilEntry("ch1-s1", "ch1.xhtml", "chapter1.mp3", start = 3.0, end = 6.0, cumulativeEnd = 8.0),
                SmilEntry("intro-s1", "intro.xhtml", "intro.mp3", start = 5.0, end = 7.0, cumulativeEnd = 10.0),
            ),
        )
    }

    /** A time that falls in the gap between two runs of a file is not answered by the interloper's entry there. */
    @Test
    fun doesNotBleedIntoTheGap() {
        // Squarely chapter1.mp3's second sentence, and in nobody's window in
        // intro.mp3 — the old widened range covered it anyway, via chapter1's
        // own entries sitting between intro's two runs.
        val entry = timeline().entryInFile("intro.mp3", at = 3.0)
        assertNull("intro.mp3 has nothing at its own time 3 — got ${entry?.fragmentId} instead", entry)
    }

    /** Each of the repeated file's own runs is still reachable at its own time. */
    @Test
    fun bothRunsStillWork() {
        val timeline = timeline()
        assertEquals("intro-s0", timeline.entryInFile("intro.mp3", at = 1.0)?.fragmentId)
        assertEquals("intro-s1", timeline.entryInFile("intro.mp3", at = 6.0)?.fragmentId)
    }

    /** The file in between is entirely unaffected by the file that surrounds it. */
    @Test
    fun theInterlopingFileIsUnaffected() {
        val timeline = timeline()
        assertEquals("ch1-s0", timeline.entryInFile("chapter1.mp3", at = 1.0)?.fragmentId)
        assertEquals("ch1-s1", timeline.entryInFile("chapter1.mp3", at = 4.0)?.fragmentId)
    }

    /** Past the end of the repeated file's last run still falls back to its final entry. */
    @Test
    fun pastTheEndFallsBackToTheLastRun() {
        assertEquals("intro-s1", timeline().entryInFile("intro.mp3", at = 999.0)?.fragmentId)
    }

    @Test
    fun unknownFile() {
        assertNull(timeline().entryInFile("nowhere.mp3", at = 0.0))
    }
}

/**
 * The end of the book. A scrub to the far end of the bar lands exactly on
 * `totalDuration`. The strictly-greater search had no entry for it, so the
 * scrub did nothing.
 */
class TimelineEndTest {
    /** Exactly the total duration is the last sentence, not nowhere. */
    @Test
    fun endIsLastEntry() {
        val timeline = SmilParser.timeline(SmilTimelineTest.book())
        val last = timeline.entries.last()
        assertEquals(last.fragmentId, timeline.entryAtBookTime(timeline.totalDuration)?.fragmentId)
        assertEquals(last.fragmentId, timeline.entryAtBookTime(timeline.totalDuration + 5)?.fragmentId)
        // Inside the last entry is unchanged.
        assertEquals(last.fragmentId, timeline.entryAtBookTime(last.cumulativeEnd - last.duration / 2)?.fragmentId)
    }
}

/** A window of sentences around the one being read: what the ten-foot read-along screen shows. */
class SmilTimelineWindowTest {
    private fun timeline(): SmilTimeline = SmilParser.timeline(SmilTimelineTest.book())

    /** The window is centred on the entry, in reading order. */
    @Test
    fun centredOnTheEntry() {
        val timeline = timeline()
        // The middle of whatever the fixture holds, so the assertion is about
        // the window and not about how many sentences somebody put in an EPUB.
        val index = timeline.entries.size / 2
        val middle = timeline.entries[index]
        val window = timeline.window(around = middle, before = 2, after = 2)!!

        assertEquals(2, window.currentIndex)
        assertEquals(middle.fragmentId, window.entries[window.currentIndex].fragmentId)
        // The neighbours are the ones the linked-list walk would have found.
        assertEquals(timeline.entryBefore(middle)?.fragmentId, window.entries[1].fragmentId)
        if (window.entries.size > 3) {
            assertEquals(timeline.entryAfter(middle)?.fragmentId, window.entries[3].fragmentId)
        }
        // Never more than asked for, and never past the ends of the book.
        assertTrue(window.entries.size <= 5)
        assertEquals(minOf(timeline.entries.size, index + 3) - maxOf(0, index - 2), window.entries.size)
    }

    /**
     * Clamped rather than padded: a short window at the start of a book is
     * honest, and blank lines in the column would read as pauses.
     */
    @Test
    fun clampsAtTheStart() {
        val timeline = timeline()
        val first = timeline.entries.first()
        val window = timeline.window(around = first, before = 3, after = 3)!!

        assertEquals(0, window.currentIndex)
        assertEquals(minOf(4, timeline.entries.size), window.entries.size)
        assertEquals(first.fragmentId, window.entries[0].fragmentId)
    }

    @Test
    fun clampsAtTheEnd() {
        val timeline = timeline()
        val last = timeline.entries.last()
        val window = timeline.window(around = last, before = 3, after = 3)!!

        val expected = minOf(4, timeline.entries.size)
        assertEquals(expected, window.entries.size)
        assertEquals(expected - 1, window.currentIndex)
        assertEquals(last.fragmentId, window.entries[window.currentIndex].fragmentId)
    }

    /** A radius of nothing is just the entry. */
    @Test
    fun zeroRadius() {
        val timeline = timeline()
        val entry = timeline.entries[timeline.entries.size / 2]
        val window = timeline.window(around = entry, before = 0, after = 0)!!

        assertEquals(1, window.entries.size)
        assertEquals(0, window.currentIndex)
    }

    /** A fragment this timeline has never heard of has no window. */
    @Test
    fun unknownFragment() {
        val timeline = timeline()
        val stranger = SmilEntry(
            fragmentId = "not-in-this-book", textHref = "x.xhtml", audioHref = "x.mp4",
            start = 0.0, end = 1.0, cumulativeEnd = 1.0,
        )
        assertNull(timeline.window(around = stranger, before = 1, after = 1))
    }
}

/** Fragment ids are unique per document, not per book. */
class ScopedFragmentTest {
    /**
     * A book that numbers sentences from scratch in every chapter — legal, and
     * what any aligner other than Storyteller's produces.
     */
    private fun timeline(): SmilTimeline {
        val entries = ArrayList<SmilEntry>()
        var cumulative = 0.0
        for (chapter in 1..3) {
            for (sentence in 1..3) {
                cumulative += 10
                entries.add(
                    SmilEntry(
                        fragmentId = "s$sentence",
                        textHref = "OEBPS/ch0$chapter.xhtml",
                        audioHref = "OEBPS/ch0$chapter.mp3",
                        start = 0.0, end = 10.0, cumulativeEnd = cumulative,
                    ),
                )
            }
        }
        return SmilTimeline(entries)
    }

    /** Next sentence stays in the chapter it was asked about. */
    @Test
    fun nextStaysPut() {
        val line = timeline()
        val third = line.entryForFragment("s1", "OEBPS/ch03.xhtml")!!
        assertEquals("OEBPS/ch03.xhtml", third.textHref)

        val next = line.entryAfter(third)!!
        assertEquals("resolving by id alone sent this to chapter 1's second sentence", "OEBPS/ch03.xhtml", next.textHref)
        assertEquals("s2", next.fragmentId)
    }

    /** Previous sentence likewise. */
    @Test
    fun previousStaysPut() {
        val line = timeline()
        val entry = line.entryForFragment("s2", "OEBPS/ch02.xhtml")!!
        val previous = line.entryBefore(entry)!!
        assertEquals("OEBPS/ch02.xhtml", previous.textHref)
        assertEquals("s1", previous.fragmentId)
    }

    /** The read-along screen shows sentences either side of the spoken one, from the right chapter. */
    @Test
    fun windowStaysPut() {
        val line = timeline()
        val entry = line.entryForFragment("s2", "OEBPS/ch03.xhtml")!!
        val window = line.window(around = entry, before = 1, after = 1)!!
        assertTrue(window.entries.all { it.textHref == "OEBPS/ch03.xhtml" })
    }

    /** An unscoped lookup still answers, with the first occurrence. */
    @Test
    fun unscopedFallsBack() {
        val line = timeline()
        val entry = line.entryForFragment("s1")!!
        assertEquals("documented as best effort", "OEBPS/ch01.xhtml", entry.textHref)
        // And a scoped one that misses still falls back, for the callers that
        // keep it.
        assertEquals("OEBPS/ch01.xhtml", line.entryForFragment("s1", "OEBPS/ch09.xhtml")?.textHref)
    }

    /**
     * The lookup for a caller that knows the document: exact, or nothing. The
     * fallback above handed chapter one's sentence to a caller asking about
     * chapter nine, and a resume labelled the answer exact.
     */
    @Test
    fun exactNeverFallsBack() {
        val line = timeline()
        val third = line.exactEntryForFragment("s2", "OEBPS/ch03.xhtml")!!
        assertEquals("OEBPS/ch03.xhtml", third.textHref)
        assertNull(line.exactEntryForFragment("s1", "OEBPS/ch09.xhtml"))
        assertNull(line.exactEntryForFragment("s9", "OEBPS/ch01.xhtml"))
        assertNull(
            "spelled differently is a different key; documentHrefs is how a caller finds the right one",
            line.exactEntryForFragment("s1", "/OEBPS/ch01.xhtml"),
        )
    }

    /** The documents narrated, each once, in book order. */
    @Test
    fun documentHrefsInOrder() {
        assertEquals(listOf("OEBPS/ch01.xhtml", "OEBPS/ch02.xhtml", "OEBPS/ch03.xhtml"), timeline().documentHrefs)
    }
}

/** "Next chapter" over a timeline that visits a document twice. */
class DocumentRunStepTest {
    /** `0 a-s0 a`, `1 b-s0 b`, `2 a-s1 a (the second visit)`, `3 c-s0 c`. */
    private fun timeline(): SmilTimeline {
        val rows = listOf("a-s0" to "OEBPS/a.xhtml", "b-s0" to "OEBPS/b.xhtml", "a-s1" to "OEBPS/a.xhtml", "c-s0" to "OEBPS/c.xhtml")
        return SmilTimeline(
            rows.withIndex().map { (index, row) ->
                SmilEntry(
                    fragmentId = row.first, textHref = row.second, audioHref = "a.mp3",
                    start = index * 5.0, end = (index + 1) * 5.0, cumulativeEnd = (index + 1) * 5.0,
                )
            },
        )
    }

    /** The run beside the one an entry is in, either way, and nothing past the ends. */
    @Test
    fun adjacentRuns() {
        val line = timeline()
        val entries = line.entries
        assertEquals(entries[3], line.firstEntryOfRunAdjacentTo(entries[2], forward = true))
        assertEquals(entries[1], line.firstEntryOfRunAdjacentTo(entries[2], forward = false))
        assertEquals("the second visit to a, not the first", entries[2], line.firstEntryOfRunAdjacentTo(entries[1], forward = true))
        assertNull(line.firstEntryOfRunAdjacentTo(entries[0], forward = false))
        assertNull(line.firstEntryOfRunAdjacentTo(entries[3], forward = true))
        assertEquals(listOf("OEBPS/a.xhtml", "OEBPS/b.xhtml", "OEBPS/c.xhtml"), line.documentHrefs)
    }
}

/** A document the spine visits twice has two spans, not one. */
class RepeatedDocumentSpanTest {
    /** notes → chapter → notes. Legal: a shared page referenced twice. */
    private fun timeline(): SmilTimeline {
        val rows = listOf(
            "OEBPS/notes.xhtml" to 2.0, "OEBPS/ch01.xhtml" to 12.0,
            "OEBPS/ch01.xhtml" to 22.0, "OEBPS/notes.xhtml" to 24.0,
        )
        return SmilTimeline(
            rows.withIndex().map { (index, row) ->
                SmilEntry(
                    fragmentId = "f$index", textHref = row.first, audioHref = "a.mp3",
                    start = 0.0, end = 2.0, cumulativeEnd = row.second,
                )
            },
        )
    }

    /** The merged range ran 0 → 24, swallowing chapter one's twenty seconds. */
    @Test
    fun firstRunIsItsOwn() {
        val span = timeline().spanOfDocument("OEBPS/notes.xhtml")!!
        assertEquals(0.0, span.start, 0.0)
        assertEquals("a 2-second page, not a 24-second one", 2.0, span.duration, 0.0)
    }

    /** And the second run is reported where it actually is. */
    @Test
    fun secondRunIsItsOwn() {
        val line = timeline()
        val second = line.entries.last()
        val span = line.spanOfDocumentContaining(second)!!
        assertEquals(22.0, span.start, 0.0)
        assertEquals(2.0, span.duration, 0.0)
    }

    /**
     * One run, spanning both of its entries: the first ends at 12 after a
     * 2-second clip, so it begins at 10, and the second ends at 22.
     */
    @Test
    fun singleRunUnchanged() {
        val span = timeline().spanOfDocument("OEBPS/ch01.xhtml")!!
        assertEquals(10.0, span.start, 0.0)
        assertEquals(12.0, span.duration, 0.0)
    }
}
