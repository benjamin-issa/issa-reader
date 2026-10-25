package com.benjaminissa.issareader.playback

import com.benjaminissa.issareader.epub.SmilTimeline
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

// Ported from `PlaybackProgressTests.swift`.

/**
 * What a progress bar stands for, and what dragging it means.
 *
 * The same numbers appear on the player, on the mini bar's hairline, on the
 * lock screen and in the car. A bar that disagrees with its own times is worse
 * than one that is merely coarse, so all four read this one value — and the
 * drag has to be its exact inverse, or a scrub on a chapter-scoped lock screen
 * lands somewhere else entirely in the book.
 */
class PlaybackProgressTest {
    /** Peter and Wendy: 5h 04m, a chapter running from 1:00:00 to 1:30:00. */
    private val book = 18_240.0
    private val chapter = ChapterSpan(3600.0, 1800.0)

    private fun progress(scope: ProgressScope, bookProgress: Double, span: ChapterSpan? = chapter) =
        PlaybackProgress(scope, bookProgress, book, span)

    // The scope itself

    /**
     * The chapter is the default, and it is first so the picker lists it first.
     * Both are asserted because the default is not written to preferences until
     * someone moves the picker — nothing on disk records it, so this is the only
     * place it is stated.
     */
    @Test
    fun chapterIsFirst() {
        assertEquals(ProgressScope.CHAPTER, ProgressScope.entries.first())
        assertEquals(2, ProgressScope.entries.size)
    }

    /**
     * "This chapter" read as a description of the bar rather than a choice of
     * scope, sitting next to "Whole book" which plainly is one.
     */
    @Test
    fun titles() {
        assertEquals("Current chapter", ProgressScope.CHAPTER.title)
        assertEquals("Whole book", ProgressScope.BOOK.title)
    }

    /**
     * The raw values are what sits in preferences, so renaming a case must not
     * quietly reset everyone who chose the other one.
     */
    @Test
    fun rawValues() {
        assertEquals("chapter", ProgressScope.CHAPTER.rawValue)
        assertEquals("book", ProgressScope.BOOK.rawValue)
    }

    // Whole book, which must not change

    /** The whole book is the bar it has always been. */
    @Test
    fun bookScope() {
        val p = progress(ProgressScope.BOOK, 0.25)
        assertFalse(p.isChapterScoped)
        assertEquals(0.25, p.fraction, 0.0)
        assertEquals(book * 0.25, p.elapsed, 0.0)
        assertEquals(book * 0.75, p.remaining, 0.0)
    }

    // Chapter

    /** A chapter bar measures the chapter, not the book. */
    @Test
    fun chapterScope() {
        // Ten minutes into a thirty-minute chapter that starts at one hour.
        val p = progress(ProgressScope.CHAPTER, 4200 / book)
        assertTrue(p.isChapterScoped)
        assertTrue(abs(p.elapsed - 600) < 0.001)
        assertTrue(abs(p.remaining - 1200) < 0.001)
        assertTrue(abs(p.fraction - 1.0 / 3.0) < 0.0001)
    }

    /** The bar reads zero at the start of a chapter and full at its end. */
    @Test
    fun chapterEnds() {
        val atStart = progress(ProgressScope.CHAPTER, 3600 / book)
        assertEquals(0.0, atStart.fraction, 0.0)
        assertTrue(abs(atStart.remaining - 1800) < 0.001)

        val atEnd = progress(ProgressScope.CHAPTER, 5400 / book)
        assertTrue(abs(atEnd.fraction - 1) < 0.0001)
        assertTrue(atEnd.remaining < 0.001)
    }

    /**
     * The moment a chapter changes, the position is briefly still in the old one
     * — or already in the next. Neither may run the bar off its ends.
     */
    @Test
    fun outsideTheChapter() {
        val before = progress(ProgressScope.CHAPTER, 60 / book)
        assertEquals(0.0, before.fraction, 0.0)
        assertEquals(0.0, before.elapsed, 0.0)

        val after = progress(ProgressScope.CHAPTER, 9000 / book)
        assertEquals(1.0, after.fraction, 0.0)
        assertEquals(0.0, after.remaining, 0.0)
    }

    // Falling back rather than dividing by zero

    /** A book with no chapters falls back to the whole book. */
    @Test
    fun noSpan() {
        val p = progress(ProgressScope.CHAPTER, 0.25, span = null)
        assertFalse(p.isChapterScoped)
        assertEquals(0.25, p.fraction, 0.0)
    }

    /** A chapter of no length falls back rather than dividing by zero. */
    @Test
    fun zeroLengthSpan() {
        val p = progress(ProgressScope.CHAPTER, 0.25, span = ChapterSpan(3600.0, 0.0))
        assertFalse(p.isChapterScoped)
        assertEquals(0.25, p.fraction, 0.0)
    }

    /** A duration that has not loaded yet yields a bar at zero, not a crash. */
    @Test
    fun noDuration() {
        for (total in listOf(0.0, Double.NaN, Double.POSITIVE_INFINITY, -5.0)) {
            val p = PlaybackProgress(ProgressScope.CHAPTER, 0.5, total, chapter)
            assertEquals(0.0, p.fraction, 0.0)
            assertEquals(0.0, p.elapsed, 0.0)
            assertEquals(0.0, p.bookProgressForFraction(0.5), 0.0)
        }
    }

    /** A non-finite position is treated as the beginning. */
    @Test
    fun nonFiniteProgress() {
        for (value in listOf(Double.NaN, Double.POSITIVE_INFINITY, -1.0, 2.0)) {
            val p = progress(ProgressScope.CHAPTER, value)
            assertTrue(p.fraction.isFinite())
            assertTrue(p.fraction >= 0 && p.fraction <= 1)
        }
    }

    /** A chapter claiming to run past the end of the book is trimmed to it. */
    @Test
    fun spanBeyondTheBook() {
        val p = progress(ProgressScope.CHAPTER, 0.99, span = ChapterSpan(18_000.0, 9999.0))
        assertTrue(p.elapsed <= p.spanDuration)
        assertTrue(p.spanStart + p.spanDuration <= book + 0.001)
    }

    // The inverse, which is what makes a drag land where it says

    /** Dragging to a fraction means the position the bar drew there. */
    @Test
    fun roundTrip() {
        for (fraction in listOf(0.0, 0.25, 0.5, 0.75, 1.0)) {
            for (scope in ProgressScope.entries) {
                val start = progress(scope, 0.3)
                val target = start.bookProgressForFraction(fraction)
                val after = progress(scope, target)
                assertTrue(
                    "$scope round trip lost $fraction → ${after.fraction}",
                    abs(after.fraction - fraction) < 0.0001,
                )
            }
        }
    }

    /** A chapter drag stays inside its chapter. */
    @Test
    fun dragStaysInTheChapter() {
        val p = progress(ProgressScope.CHAPTER, 4200 / book)
        val atStart = p.bookProgressForFraction(0.0) * book
        val atEnd = p.bookProgressForFraction(1.0) * book
        assertTrue(abs(atStart - 3600) < 0.001)
        assertTrue(abs(atEnd - 5400) < 0.001)
    }

    /**
     * The lock screen reports a drag in the same units as the duration it was
     * given, so this has to invert exactly what was published.
     */
    @Test
    fun secondsInverse() {
        val p = progress(ProgressScope.CHAPTER, 4200 / book)
        // The system was told the bar is `spanDuration` long and `elapsed` in.
        val position = p.bookProgressForSeconds(p.elapsed) * book
        assertTrue(abs(position - 4200) < 0.001)
        // Dragging to the middle of the chapter is 15 minutes in.
        val middle = p.bookProgressForSeconds(900.0) * book
        assertTrue(abs(middle - 4500) < 0.001)
    }

    /** A scrub past either end of the bar clamps into the book. */
    @Test
    fun scrubOutOfRange() {
        val p = progress(ProgressScope.CHAPTER, 4200 / book)
        assertTrue(p.bookProgressForFraction(-1.0) >= 0)
        assertTrue(p.bookProgressForFraction(5.0) <= 1)
        assertTrue(p.bookProgressForSeconds(-100.0) >= 0)
        assertTrue(p.bookProgressForSeconds(99_999.0) <= 1)
    }

    // The whole book, whatever the bar is scoped to

    /**
     * The player's book line reads these two, and the point of them is that
     * they ignore the scope. A chapter-scoped bar is the default, so if these
     * followed the span they would be wrong almost all of the time.
     */
    @Test
    fun bookFiguresIgnoreScope() {
        val chapterScoped = PlaybackProgress(ProgressScope.CHAPTER, 0.25, 36000.0, ChapterSpan(7200.0, 3600.0))
        assertTrue("the bar really is chapter-scoped", chapterScoped.isChapterScoped)
        // 25% of ten hours gone, so seven and a half hours left — not the
        // remainder of the chapter, which is what `remaining` gives.
        assertEquals(27000.0, chapterScoped.bookRemaining, 0.0)
        assertEquals(25, chapterScoped.bookPercentComplete)
        assertNotEquals(chapterScoped.bookRemaining, chapterScoped.remaining, 0.0)

        val bookScoped = PlaybackProgress(ProgressScope.BOOK, 0.25, 36000.0, null)
        assertEquals(chapterScoped.bookRemaining, bookScoped.bookRemaining, 0.0)
        assertEquals(chapterScoped.bookPercentComplete, bookScoped.bookPercentComplete)
    }

    /**
     * The condition the player hides the whole line on. If this ever returned
     * something other than zero, a book whose manifest had not loaded would
     * print a confident "0m left in book".
     */
    @Test
    fun noDurationLeavesNothingInTheBook() {
        val progress = PlaybackProgress(ProgressScope.BOOK, 0.5, 0.0, null)
        assertEquals(0.0, progress.bookDuration, 0.0)
        assertEquals(0.0, progress.bookRemaining, 0.0)
    }

    /** The ends of the book read as nothing done and nothing left. */
    @Test
    fun bookEnds() {
        for ((bookProgress, remaining, percent) in listOf(Triple(0.0, 36000.0, 0), Triple(1.0, 0.0, 100))) {
            val progress = PlaybackProgress(ProgressScope.BOOK, bookProgress, 36000.0, null)
            assertEquals(remaining, progress.bookRemaining, 0.0)
            assertEquals(percent, progress.bookPercentComplete)
        }
    }

    /**
     * Never negative, whatever a server sends. `bookProgress` is clamped by the
     * constructor, and this is the assertion that says so out loud.
     */
    @Test
    fun pastTheEnd() {
        val progress = PlaybackProgress(ProgressScope.BOOK, 1.4, 36000.0, null)
        assertTrue(progress.bookRemaining >= 0)
        assertTrue(progress.bookPercentComplete <= 100)
    }
}

/** The read-along's idea of a chapter: a spine text document. Ported from `DocumentSpanTests`. */
class DocumentSpanTest {
    private fun timeline(): SmilTimeline = readalongTimeline().first

    /** A document's span runs from its first sentence to its last. */
    @Test
    fun span() {
        val timeline = timeline()
        val href = "OEBPS/ch01.xhtml"
        val entries = timeline.entriesInDocument(href)
        val span = checkNotNull(timeline.spanOfDocument(href))

        val first = entries.first()
        val last = entries.last()
        assertTrue(abs(span.start - (first.cumulativeEnd - first.duration)) < 0.0001)
        assertTrue(abs(span.start + span.duration - last.cumulativeEnd) < 0.0001)
    }

    /** The first document starts at the beginning of the book. */
    @Test
    fun firstDocument() {
        val timeline = timeline()
        val span = checkNotNull(timeline.spanOfDocument(timeline.entries.first().textHref))
        assertTrue(span.start < 0.0001)
    }

    /** The last document ends at the end of the book. */
    @Test
    fun lastDocument() {
        val timeline = timeline()
        val span = checkNotNull(timeline.spanOfDocument(timeline.entries.last().textHref))
        assertTrue(abs(span.start + span.duration - timeline.totalDuration) < 0.0001)
    }

    /** Documents tile the book without gaps or overlaps. */
    @Test
    fun documentsTile() {
        val timeline = timeline()
        val seen = ArrayList<String>()
        for (entry in timeline.entries) if (seen.lastOrNull() != entry.textHref) seen.add(entry.textHref)
        var previousEnd = 0.0
        for (href in seen) {
            val span = checkNotNull(timeline.spanOfDocument(href))
            assertTrue("$href does not follow the one before", abs(span.start - previousEnd) < 0.0001)
            previousEnd = span.start + span.duration
        }
        assertTrue(abs(previousEnd - timeline.totalDuration) < 0.0001)
    }

    /** A document with no narration has no span. */
    @Test
    fun unknownDocument() {
        assertNull(timeline().spanOfDocument("OEBPS/not-a-chapter.xhtml"))
    }

    /** An empty timeline has no spans at all. */
    @Test
    fun emptyTimeline() {
        assertNull(SmilTimeline(emptyList()).spanOfDocument("anything"))
    }
}
