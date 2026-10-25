package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.sync.StagedBooks
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.Instant

/**
 * The year a book was published, read the way the server wrote it. Ported
 * from `PublishedYearTextTests.swift`.
 *
 * Both server generations store a bare year as that year's first midnight in
 * UTC. Read in any other zone, one edge of the year moves. The two cases
 * between them fail for a reading in any zone but UTC, wherever the suite runs.
 */
class PublishedYearTextTest {
    /** A bare year's first midnight in UTC is that year. */
    @Test
    fun firstMidnight() {
        assertEquals("1994", PublishedYearText.text(Instant.parse("1994-01-01T00:00:00Z")))
    }

    /** The last second of the year before is still the year before. */
    @Test
    fun lastSecondBefore() {
        assertEquals("1993", PublishedYearText.text(Instant.parse("1993-12-31T23:59:59Z")))
    }

    /** The More by caption says the same year: the caption is the one in this package. */
    @Test
    fun captionAgrees() {
        val json = bookJson(uuid = "emma", title = "Emma")
        json["publicationDate"] = "1994-01-01T00:00:00.000Z"
        val book = decodeBook(json)
        val published = book.publicationDate!!.value
        assertEquals(PublishedYearText.text(published), StagedBooks.authorCaption(book))
        assertEquals("1994", StagedBooks.authorCaption(book))
    }
}
