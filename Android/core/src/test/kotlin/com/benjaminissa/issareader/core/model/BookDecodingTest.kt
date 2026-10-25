package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.networking.StorytellerDate
import com.benjaminissa.issareader.core.sync.LibraryMutationService
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneOffset
import kotlin.math.abs

/**
 * These decode a real `GET /api/v2/books` response captured from a running
 * Storyteller `web-v2.14.21` server (Tests/Fixtures/books.json). Hand-written
 * sample JSON would only prove the model agrees with itself. Ported from
 * `BookDecodingTests.swift`.
 */
class BookDecodingTest {
    /** Decodes the full library payload. */
    @Test
    fun decodesLibrary() {
        val books = fixtureBooks("books")
        assertEquals(5, books.size)

        val alice = books.first { it.title.startsWith("Alice") }
        assertEquals("Lewis Carroll", alice.byline)
        assertEquals("Carroll, Lewis", alice.authors.first().fileAs)
        assertEquals(83L, alice.ebook?.pageCount)
        assertEquals(setOf(BookFormat.EBOOK), alice.availableFormats)
        assertFalse(alice.hasReadalong)
        assertNull(alice.progress)
        // uuid is identity; the integer `id` is legacy and must not be the key.
        assertEquals(alice.uuid, alice.id)
        assertNotNull(alice.legacyId)
    }

    /** Parses both date formats the server mixes in one object. */
    @Test
    fun parsesBothDateFormats() {
        val book = fixtureBooks("books").first()
        // createdAt is SQLite-shaped: "2026-08-30 03:51:47"
        val created = book.createdAt!!.value
        // publicationDate is ISO 8601 with fractional seconds and a Z suffix.
        val published = book.publicationDate!!.value
        assertTrue(published.isBefore(created))
    }

    /** Every book carries a per-user status, so one request yields catalogue and progress. */
    @Test
    fun carriesPerUserState() {
        val books = fixtureBooks("books")
        for (book in books) assertNotNull("${book.title} has no status", book.status)
        assertTrue(books.all { it.status?.name == Status.toReadName })
    }
}

/** Ported from `BookDecodingTests.swift` (`StorytellerDateTests`). */
class StorytellerDateTest {
    /** Parses the SQLite row-timestamp format as UTC. */
    @Test
    fun parsesSqliteFormat() {
        val date = StorytellerDate.parse("2026-08-30 03:51:47")!!.atZone(ZoneOffset.UTC)
        assertEquals(2026, date.year)
        assertEquals(8, date.monthValue)
        assertEquals(30, date.dayOfMonth)
        assertEquals(3, date.hour)
        assertEquals(47, date.second)
    }

    /** Parses ISO 8601 with and without fractional seconds. */
    @Test
    fun parsesIsoFormats() {
        val withMillis = StorytellerDate.parse("1998-06-01T00:00:00.000Z")
        val withoutMillis = StorytellerDate.parse("1998-06-01T00:00:00Z")
        assertNotNull(withMillis)
        assertEquals(withMillis, withoutMillis)
    }

    /** Rejects garbage rather than silently returning a wrong instant. */
    @Test
    fun rejectsGarbage() {
        assertNull(StorytellerDate.parse("not a date"))
        assertNull(StorytellerDate.parse(""))
    }
}

/**
 * Regression tests for the date formats a live server actually returns.
 * Ported from `BookDecodingTests.swift` (`StorytellerDateFormatRegressionTests`).
 *
 * The JavaScript form only appears on `alignedAt`, so it stays dormant until
 * the first readaloud exists — and then fails the whole library decode at once,
 * which reads as an empty library rather than an error.
 */
class StorytellerDateFormatRegressionTest {
    /** Parses the JavaScript Date.toString form used by alignedAt. */
    @Test
    fun parsesJavaScriptDate() {
        val raw = "Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)"
        val date = StorytellerDate.parse(raw)!!.atZone(ZoneOffset.UTC)
        assertEquals(2026, date.year)
        assertEquals(8, date.monthValue)
        assertEquals(30, date.dayOfMonth)
        assertEquals(5, date.hour)
        assertEquals(1, date.minute)
        assertEquals(37, date.second)
    }

    /** Handles a non-UTC offset and a missing timezone name. */
    @Test
    fun parsesOffsetVariants() {
        assertNotNull(StorytellerDate.parse("Sun Aug 30 2026 05:01:37 GMT+0000"))
        val offset = StorytellerDate.parse("Mon Jan 05 2026 12:00:00 GMT-0500 (Eastern Standard Time)")!!
        val utcNoon = StorytellerDate.parse("2026-01-05 17:00:00")!!
        assertTrue(abs(offset.epochSecond - utcNoon.epochSecond) < 1)
    }

    /** All three server formats decode in one object. */
    @Test
    fun allThreeInOneBook() {
        val json = """
            [{"uuid":"u1","id":1,"title":"Aligned Book",
              "createdAt":"2026-08-30 04:38:08",
              "updatedAt":"2026-08-30 04:38:08",
              "publicationDate":"2008-06-27T00:00:00.000Z",
              "alignedAt":"Sun Aug 30 2026 05:01:37 GMT+0000 (Coordinated Universal Time)",
              "authors":[],"narrators":[],"creators":[],"series":[],"tags":[],
              "collections":[],"identifiers":[]}]
        """.trimIndent()
        val book = IssaJson.decodeFromString(ListSerializer(Book.serializer()), json).first()
        assertNotNull(book.createdAt)
        assertNotNull(book.publicationDate)
        assertNotNull(book.alignedAt)
    }
}

/** The rating endpoint has an unusual contract worth pinning down. Ported from `BookDecodingTests.swift` (`RatingContractTests`). */
class RatingContractTest {
    /** A rating write encodes only the fields that were set. */
    @Test
    fun encodesSparsely() {
        val onlyScore = LibraryMutationService.Rating(rating = 4.0)
        val json = IssaJson.parseToJsonElement(
            IssaJson.encodeToString(LibraryMutationService.Rating.serializer(), onlyScore),
        ).jsonObject
        assertEquals(4.0, json["rating"]!!.jsonPrimitive.double, 0.0)
        // The server answers 405, not 400, for a body it dislikes, so sending
        // an explicit null review where none was given is worth avoiding.
        assertNull(json["review"])
    }

    /** Decodes the full row the server returns. */
    @Test
    fun decodesServerRow() {
        // Captured from a live PUT: the response carries more than it accepts.
        val json = """
            {"uuid":"f4b40e3d","userId":"229a0d40","bookUuid":"35f8896e",
             "rating":4,"review":null,
             "createdAt":"2026-08-30 09:13:48","updatedAt":"2026-08-30 09:13:48"}
        """.trimIndent()
        val rating = IssaJson.decodeFromString(LibraryMutationService.Rating.serializer(), json)
        assertEquals(4.0, rating.rating!!, 0.0)
        assertNull(rating.review)
    }
}

/**
 * Captured from a live 2.14.21 server after seeding an ISBN, an Audible ASIN
 * and a Hardcover rating. The shape here is not guessable from the docs: an
 * identifier arrives as its *type* joined to the value, so `uuid` is the type's
 * and the display name lives in `name`. Ported from `BookDecodingTests.swift`
 * (`IdentifierDecodingTests`).
 */
class IdentifierDecodingTest {
    private fun books(): List<Book> = fixtureBooks("book-with-identifiers")

    /** An identifier decodes with the label a reader would recognise. */
    @Test
    fun identifiers() {
        val book = books().first()
        assertEquals(2, book.identifiers.size)
        val isbn = book.identifiers.first { it.kind == "isbn-13" }
        assertEquals("ISBN-13", isbn.label)
        assertEquals("9780141439518", isbn.value)
        // No template configured on this server, so there is nothing to link to
        // and the UI must not invent a URL.
        assertNull(isbn.url)
    }

    /** An identifier with no name falls back to its slug, never to nothing. */
    @Test
    fun labelFallback() {
        assertEquals("AUDIBLE", Identifier(kind = "audible").label)
        assertEquals("Identifier", Identifier().label)
    }

    /** A url template is filled in with the identifier's value. */
    @Test
    fun urlTemplate() {
        val identifier = Identifier(
            kind = "hardcover-book-slug", urlTemplate = "https://hardcover.app/books/{value}",
            value = "pride-and-prejudice",
        )
        assertEquals("https://hardcover.app/books/pride-and-prejudice", identifier.url.toString())
    }

    /** An external rating keeps its own scale: sources do not agree on one, so the scale travels with the rating. */
    @Test
    fun externalRating() {
        val book = books().first()
        val hardcover = book.externalData!!.first()
        assertEquals("Hardcover", hardcover.sourceName)
        assertEquals("4.3 of 5", hardcover.ratingText)
        assertEquals(4.31 / 5, hardcover.normalized!!, 0.0)
    }

    /** A source with no stated maximum is not drawn on a scale we made up. */
    @Test
    fun unknownScale() {
        val data = ExternalData(uuid = "x", rating = 87.0, sourceName = "Somewhere")
        assertNull(data.normalized)
        assertEquals("87", data.ratingText)
    }
}

