package com.benjaminissa.issareader.app.ui.book

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.sync.SeriesGroup
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Two small decisions on the book screen that a server's data can upset: Swift's `BookDetailLabelTests`. */
class BookDetailLabelTest {
    /**
     * The rating is the server's number, and the label turned it into a whole
     * number directly: one malformed rating crashed the book's page.
     */
    @Test
    fun `a rating out of range is spoken as the stars there are, not a crash`() {
        assertEquals("Your rating, 5 stars", BookDetail.ratingLabel(1e300))
        assertEquals("Your rating, 0 stars", BookDetail.ratingLabel(-1e300))
        assertEquals("Your rating, 0 stars", BookDetail.ratingLabel(Double.POSITIVE_INFINITY))
        assertEquals("Your rating, 0 stars", BookDetail.ratingLabel(Double.NaN))
    }

    @Test
    fun `an ordinary rating reads as it always did`() {
        assertEquals("Your rating, 1 star", BookDetail.ratingLabel(1.0))
        assertEquals("Your rating, 3 stars", BookDetail.ratingLabel(3.0))
        assertEquals("Your rating, not rated. Rate this book from one to five stars.", BookDetail.ratingLabel(null))
    }

    /**
     * The series line's identifier sat on the first *membership*; when that
     * one is a series of one — plain text, no link — no element carried it.
     */
    @Test
    fun `the series identifier goes on the first membership that is a link`() {
        val book = book(series = listOf("Standalone Shorts", "The Barsetshire Chronicles"))
        val linked = SeriesGroup(name = "The Barsetshire Chronicles", books = listOf(book, book))
        assertEquals(book.series[1].id, BookDetail.firstLinkedSeriesId(book.series, listOf(linked)))
        assertNull(BookDetail.firstLinkedSeriesId(book.series, emptyList()))
    }

    @Test
    fun `a tag links only when another book shares it`() {
        val book = book(series = emptyList())
        val other = book.copy(uuid = "other")
        assertEquals(true, BookDetail.isLinked("Classics", mapOf("Classics" to listOf(book, other))))
        assertEquals(false, BookDetail.isLinked("Classics", mapOf("Classics" to listOf(book))))
        assertEquals(false, BookDetail.isLinked("Fiction", mapOf("Classics" to listOf(book, other))))
    }

    @Test
    fun `the status glyph follows the built-in name, never the label`() {
        assertEquals(com.benjaminissa.issareader.ui.Symbols.book, BookDetail.symbol("Reading"))
        assertEquals(com.benjaminissa.issareader.ui.Symbols.checkmarkCircle, BookDetail.symbol("Read"))
        assertEquals(com.benjaminissa.issareader.ui.Symbols.bookmark, BookDetail.symbol("To read"))
        assertEquals(com.benjaminissa.issareader.ui.Symbols.bookmark, BookDetail.symbol(null))
    }

    @Test
    fun `an alignment stage reads as Swift capitalises it`() {
        assertEquals("Processing", BookDetail.capitalized("PROCESSING"))
        assertEquals("Not Started", BookDetail.capitalized("not started"))
    }

    private fun book(series: List<String>): Book {
        val json = buildJsonObject {
            put("uuid", "warden")
            put("title", "The Warden")
            putJsonArray("authors") {}
            putJsonArray("narrators") {}
            putJsonArray("creators") {}
            putJsonArray("collections") {}
            putJsonArray("identifiers") {}
            putJsonArray("tags") {}
            putJsonArray("series") {
                series.forEachIndexed { index, name ->
                    add(buildJsonObject { put("uuid", "series-$index"); put("name", name); put("position", 1) })
                }
            }
        }
        return IssaJson.decodeFromString(Book.serializer(), json.toString())
    }
}
