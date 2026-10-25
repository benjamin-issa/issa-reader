package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.fixtureBooks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The subtitle a book screen should show. Ported from `BookSubtitleTests.swift`.
 *
 * `Book.subtitle` decodes, is written to the catalogue, and is flattened into
 * the search index — typing "afternoon" finds *Alice's Adventures in
 * Wonderland* on the strength of it alone (`StoreTest`). The book details
 * screen, which shows the description from the very same response, showed
 * nothing. This is the rule that decides what it now shows.
 */
class BookSubtitleTest {
    /** Decoded, like every other fixture: the model is only ever decoded. */
    private fun book(title: String, subtitle: String?): Book {
        val json = bookJson(uuid = title, title = title)
        if (subtitle != null) json["subtitle"] = subtitle
        return decodeBook(json)
    }

    /**
     * The subtitle the live server sends arrives intact and is shown as sent.
     * From the captured `web-v2.14.21` response, not a hand-written sample:
     * the point of the change is that this value was already arriving.
     */
    @Test
    fun aRealSubtitleSurvivesTheRoundTrip() {
        val books = fixtureBooks("books")
        val alice = books.first { it.title.startsWith("Alice") }
        assertEquals("A Tale for a Summer Afternoon", alice.displaySubtitle)
    }

    /**
     * A book the server sends no subtitle for has none to show. Four of the
     * five books in that same response send `null`, which is the ordinary
     * case: the row has to vanish rather than leave a gap under the title.
     */
    @Test
    fun mostBooksHaveNoSubtitle() {
        val books = fixtureBooks("books")
        val without = books.filter { it.displaySubtitle == null }
        assertEquals("only Alice carries a subtitle in this capture", 4, without.size)
        assertTrue(without.all { it.subtitle == null })
    }

    /**
     * A subtitle of nothing but blank space is not a subtitle. A non-empty
     * check at the call site passes for a string of spaces, which draws an
     * invisible line that still takes a row of height and the gap with it.
     */
    @Test
    fun blankSubtitlesAreNotShown() {
        assertNull(book("Dracula", subtitle = "").displaySubtitle)
        assertNull(book("Dracula", subtitle = "   ").displaySubtitle)
        assertNull(book("Dracula", subtitle = "\n\t ").displaySubtitle)
    }

    /**
     * Surrounding whitespace is trimmed rather than drawn. Metadata lifted out
     * of an EPUB carries whatever whitespace the packager left around it, and
     * a leading space is a visible indent on a line set hard against the
     * title above it.
     */
    @Test
    fun surroundingWhitespaceIsTrimmed() {
        assertEquals(
            "A Tale for a Summer Afternoon",
            book("Alice", subtitle = "  A Tale for a Summer Afternoon\n").displaySubtitle,
        )
    }

    /**
     * A subtitle that happens to repeat the title is still passed through.
     * Deliberately *not* de-duplicated against the title: the one subtitle in
     * the captured response is a different sentence, and suppressing a case
     * nothing has produced would be a rule with no bug behind it.
     */
    @Test
    fun aRepeatedTitleIsNotSuppressed() {
        assertEquals("Emma", book("Emma", subtitle = "Emma").displaySubtitle)
    }
}
