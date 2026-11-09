package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.reader.ChapterContents
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * How the player says how much of a book is left. Ported from
 * `BookReadoutTests.swift`; Swift's `PlayerView` statics are [PlayerReadout].
 */
class BookReadoutTest : AppSuite() {
    /** A length reads in units, not as a clock. */
    @Test
    fun durationText() {
        for ((seconds, expected) in listOf(
            (4 * 3600 + 12 * 60).toDouble() to "4h 12m",
            (47 * 60).toDouble() to "47m",
            // On the hour, and the zero minutes are kept.
            3600.0 to "1h 0m",
            0.0 to "0m",
        )) {
            assertEquals(expected, PlayerReadout.durationText(seconds))
        }
    }

    /** Seconds round rather than truncate. */
    @Test
    fun rounding() {
        assertEquals("4h 13m", PlayerReadout.durationText((4 * 3600 + 12 * 60 + 50).toDouble()))
        assertEquals("4h 12m", PlayerReadout.durationText((4 * 3600 + 12 * 60 + 10).toDouble()))
    }

    /** Nothing sensible comes back from a nonsense duration, and nothing crashes. */
    @Test
    fun nonsense() {
        assertEquals("0m", PlayerReadout.durationText(-60.0))
        assertEquals("0m", PlayerReadout.durationText(Double.NaN))
        assertEquals("0m", PlayerReadout.durationText(Double.POSITIVE_INFINITY))
        assertEquals("0m", PlayerReadout.durationText(1e300))
        assertEquals("no time", PlayerReadout.spokenDuration(-60.0))
        assertEquals("no time", PlayerReadout.spokenDuration(Double.NaN))
        assertEquals("no time", PlayerReadout.spokenDuration(Double.POSITIVE_INFINITY))
        assertEquals("no time", PlayerReadout.spokenDuration(1e300))
    }

    /** A position reads as a clock, with the hour dropped under one. */
    @Test
    fun timeText() {
        for ((seconds, expected) in listOf(
            0.0 to "0:00",
            7.0 to "0:07",
            67.0 to "1:07",
            (47 * 60 + 31).toDouble() to "47:31",
            (4 * 3600 + 12 * 60).toDouble() to "4:12:00",
            3600.0 to "1:00:00",
        )) {
            assertEquals(expected, PlayerReadout.timeText(seconds))
        }
    }

    /** A nonsense position prints nothing rather than crashing the player. */
    @Test
    fun nonsensePosition() {
        assertEquals("0:00", PlayerReadout.timeText(1e300))
        assertEquals("0:00", PlayerReadout.timeText(Double.NaN))
        assertEquals("0:00", PlayerReadout.timeText(Double.POSITIVE_INFINITY))
        assertEquals("0:00", PlayerReadout.timeText(Double.NEGATIVE_INFINITY))
        assertEquals("0:00", PlayerReadout.timeText(-60.0))
        assertEquals("0:00", PlayerReadout.timeText(1e300 * 0.5))
        assertEquals("0:00", PlayerReadout.timeText(1e300 * (1 - 0.5)))
        assertEquals("99:00:00", PlayerReadout.timeText(99.0 * 3600))
    }

    /** The spoken form is words, and singular where it should be. */
    @Test
    fun spokenDuration() {
        for ((seconds, expected) in listOf(
            (4 * 3600 + 12 * 60).toDouble() to "4 hours 12 minutes",
            3600.0 to "1 hour",
            60.0 to "1 minute",
            (47 * 60).toDouble() to "47 minutes",
            (2 * 3600 + 60).toDouble() to "2 hours 1 minute",
        )) {
            assertEquals(expected, PlayerReadout.spokenDuration(seconds))
        }
    }
}

/**
 * The table of contents, built once instead of per rendered row. Ported from
 * `ChapterContentsTests.swift`; Swift's `ChapterListView.build` is
 * [ChapterContents.build].
 */
class ChapterContentsTest : AppSuite() {
    private fun alice(): EpubPackage = EpubPackage.open(Fixtures.epub("alice.epub"))

    /** Every navigation point that resolves gets its own row. */
    @Test
    fun oneRowPerNavPoint() {
        val epubPackage = alice()
        val hrefs = epubPackage.spine.map { it.href }.toSet()
        val expected = epubPackage.navigation.filter { it.href in hrefs }
        assertFalse("the fixture has to have navigation for this to test anything", expected.isEmpty())

        val entries = ChapterContents.build(epubPackage)
        assertEquals(expected.size, entries.size)
        assertEquals(
            expected.mapIndexed { index, point -> point.title.ifEmpty { "Chapter ${index + 1}" } },
            entries.map { it.title },
        )
        assertEquals(expected.map { it.fragment }, entries.map { it.fragment })
    }

    /** Each row points at the spine item its navigation entry names. */
    @Test
    fun rowsPointAtTheRightChapter() {
        val epubPackage = alice()
        for (entry in ChapterContents.build(epubPackage)) {
            val href = epubPackage.navigation.first { it.fragment == entry.fragment && it.title == entry.title }.href
            val expected = epubPackage.spine.indexOfFirst { it.href == href }
            assertTrue(expected >= 0)
            assertEquals("\"${entry.title}\" opens spine item ${entry.spineIndex}, not $expected", expected, entry.spineIndex)
        }
    }

    /** Row ids are unique. */
    @Test
    fun idsAreUnique() {
        val entries = ChapterContents.build(alice())
        assertEquals(entries.size, entries.map { it.id }.toSet().size)
    }

    /** No navigation at all still yields a row per spine item. */
    @Test
    fun fallsBackToTheSpine() {
        val epubPackage = alice()
        val stripped = epubPackage.copy(navigation = emptyList(), frontMatter = emptySet())
        val entries = ChapterContents.build(stripped)
        assertEquals(epubPackage.spine.size, entries.size)
        assertEquals(epubPackage.spine.indices.toList(), entries.map { it.spineIndex })
        assertTrue(entries.all { it.fragment == null })
    }

    /** No book at all yields no rows. */
    @Test
    fun noPackageNoRows() {
        assertTrue(ChapterContents.build(null).isEmpty())
    }
}

/**
 * The book screen says why "Save for offline" did nothing. Ported from
 * `BookDetailRefusalTests.swift`; Swift's `BookDetailView.refusal` is
 * [BookActions.refusal].
 */
class BookDetailRefusalTest : AppSuite() {
    /** The refused edition shows the reason, and only that edition. */
    @Test
    fun refusalIsShownAgainstItsEdition() = mainTest {
        val fixture = DownloadRefusalTest.fixture(testScope())
        try {
            val app = fixture.app
            val book = checkNotNull(app.bookByUuid[DownloadRefusalTest.uuid])

            assertNull(BookActions.refusal(book, BookContentService.Format.READALOUD, app.downloadRefusals))
            val started = app.download(book, BookContentService.Format.READALOUD)
            assertFalse(started)

            assertEquals(
                DownloadRefusalTest.expectedReason,
                BookActions.refusal(book, BookContentService.Format.READALOUD, app.downloadRefusals),
            )
            assertNull(
                "another edition was not refused",
                BookActions.refusal(book, BookContentService.Format.EBOOK, app.downloadRefusals),
            )
        } finally {
            fixture.tearDown()
        }
    }
}
