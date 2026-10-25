package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.fixture
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.fixtureStatuses
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.core.sync.LibraryService.CoverShape
import com.benjaminissa.issareader.core.withTemporaryDirectory
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * These decode a real `GET /api/v2/books` response captured from a running
 * Storyteller `web-v3.0.0-beta.40` server (Tests/Fixtures/v3/books.json),
 * migrated from the same library as the 2.14.21 capture, with the shapes 3.x
 * adds put there on purpose: "Read" relabelled "Finished", a custom
 * "Abandoned" status, and two books whose status was cleared — one of them
 * with a position. Ported from `BookDecodingV3Tests.swift`.
 */
class BookDecodingV3Test {
    private fun books(): List<Book> = fixtureBooks("v3/books")

    private fun book(title: String): Book = books().firstOrNull { it.title == title } ?: error("no $title in the capture")

    /**
     * The whole 3.x library decodes, every book of it.
     *
     * First, and on the whole array: one book that fails to decode throws the
     * entire catalogue away, so a refresh on a 3.x server would update
     * nothing. Per-book assertions below would never notice that.
     */
    @Test
    fun decodesWholeLibrary() {
        val books = books()
        assertEquals(25, books.size)
        assertEquals(25, LibraryService.refusingUnsafeIdentifiers(books).size)
    }

    /** A cleared status decodes as no status. */
    @Test
    fun nullStatus() {
        assertNull(book("Emma").status)
        val timeMachine = book("The Time Machine")
        assertNull(timeMachine.status)
        assertEquals("the one with a position, for the shelf rule", 0.3, timeMachine.progress!!, 0.0)
    }

    /** A relabelled status keeps its name and shows its label: 3.x fixes the built-in names and puts the admin's wording in `label`. */
    @Test
    fun relabelledStatus() {
        val status = book("Peter and Wendy").status!!
        assertEquals(Status.readName, status.name)
        assertEquals("Finished", status.label)
        assertEquals("Finished", status.displayName)
    }

    /** A custom status carries its own name as its label. */
    @Test
    fun customStatus() {
        val status = book("Moby Dick; Or, The Whale").status!!
        assertEquals("Abandoned", status.name)
        assertEquals("Abandoned", status.displayName)
    }

    /** Each format carries its own cover reference. */
    @Test
    fun coverReferences() {
        val peter = book("Peter and Wendy")
        val ebook = peter.ebook!!.cover!!
        val audiobook = peter.audiobook!!.cover!!
        val readaloud = peter.readaloud!!.cover!!
        assertEquals("59965a29b5d464a02877c179a65183efefe8bec52fd55b8df86e4394c675f7e2", ebook.sha256)
        assertEquals("35480043e658db2732bcfd22d98a8e990b287973cbf568f85306fb0e2e0cef3b", audiobook.sha256)
        assertEquals("the read-along was made from this ebook", ebook, readaloud)
        assertTrue(listOf(ebook, audiobook, readaloud).all { it.isUsable })

        // Every ebook in the capture has art; a missing format is null whole.
        assertTrue(books().all { it.ebook?.cover?.isUsable == true })
        assertNull(book("Emma").audiobook)
    }

    /**
     * Portrait is the ebook's cover, else the read-along's; square is the
     * audiobook's — the choice 3.x's own cover route makes: `audio` →
     * audiobook, otherwise ebook, else read-along.
     */
    @Test
    fun coverShapeMapping() {
        val peter = book("Peter and Wendy")
        assertEquals(peter.ebook?.cover, peter.coverReference(CoverShape.PORTRAIT))
        assertEquals(peter.audiobook?.cover, peter.coverReference(CoverShape.SQUARE))

        val noEbookArt = peter.copy(
            ebook = peter.ebook?.copy(cover = null),
            readaloud = peter.readaloud?.copy(cover = CoverReference("e".repeat(64))),
        )
        assertEquals(noEbookArt.readaloud?.cover, noEbookArt.coverReference(CoverShape.PORTRAIT))

        val noEbook = peter.copy(ebook = null)
        assertEquals(peter.readaloud?.cover, noEbook.coverReference(CoverShape.PORTRAIT))

        val badEbookArt = noEbookArt.copy(ebook = noEbookArt.ebook?.copy(cover = CoverReference("NOT-A-SHA")))
        assertEquals(noEbookArt.readaloud?.cover, badEbookArt.coverReference(CoverShape.PORTRAIT))

        val emma = book("Emma")
        assertNull("no audiobook, no square art", emma.coverReference(CoverShape.SQUARE))
        assertEquals(emma.ebook?.cover, emma.coverReference(CoverShape.PORTRAIT))

        // Falling back is the uuid route's answer to a portrait 404, so it
        // changes nothing for a book with portrait art, and a square never
        // falls back the other way.
        assertEquals(peter.ebook?.cover, peter.coverReference(CoverShape.PORTRAIT, fallback = true))
        assertNull(emma.coverReference(CoverShape.SQUARE, fallback = true))
        val squareOnly = peter.copy(ebook = null, readaloud = null)
        assertNull(squareOnly.coverReference(CoverShape.PORTRAIT))
        assertEquals(peter.audiobook?.cover, squareOnly.coverReference(CoverShape.PORTRAIT, fallback = true))
    }

    /**
     * A malformed cover reads as no cover, and the library still decodes.
     *
     * 1.2.0 ignored the `cover` key, so a reshaped one must cost that cover
     * and nothing more: a book that fails to decode takes the whole refresh
     * with it. Three shapes beta.40 never sends, on the capture itself.
     */
    @Test
    fun malformedCover() {
        val library = (IssaJson.parseToJsonElement(fixture("v3/books")) as JsonArray).map { it.jsonObject }.toMutableList()

        val peterIndex = library.indexOfFirst { it["title"]?.jsonPrimitive?.content == "Peter and Wendy" }
        val peter = library[peterIndex]
        library[peterIndex] = JsonObject(
            peter + mapOf(
                "ebook" to JsonObject(peter["ebook"]!!.jsonObject + ("cover" to JsonObject(emptyMap()))),
                "audiobook" to JsonObject(peter["audiobook"]!!.jsonObject + ("cover" to JsonPrimitive("x"))),
            ),
        )

        val emmaIndex = library.indexOfFirst { it["title"]?.jsonPrimitive?.content == "Emma" }
        val emma = library[emmaIndex]
        library[emmaIndex] = JsonObject(
            emma + ("ebook" to JsonObject(emma["ebook"]!!.jsonObject + ("cover" to buildJsonObject { put("sha256", 42) }))),
        )

        val books = IssaJson.decodeFromJsonElement(ListSerializer(Book.serializer()), JsonArray(library))
        assertEquals(25, books.size)

        val decodedPeter = books.first { it.title == "Peter and Wendy" }
        assertFalse("an object with no hash", decodedPeter.ebook?.cover?.isUsable ?: true)
        assertNull("not an object at all", decodedPeter.coverReference(CoverShape.SQUARE))
        assertEquals(
            "an unreadable ebook cover falls through to the read-along's, like an unusable one",
            decodedPeter.readaloud?.cover, decodedPeter.coverReference(CoverShape.PORTRAIT),
        )

        val decodedEmma = books.first { it.title == "Emma" }
        assertNull("a hash that is not a string", decodedEmma.coverReference(CoverShape.PORTRAIT))
        assertNotNull("the format itself still decodes", decodedEmma.ebook?.uuid)
    }

    /** The 3.x status list decodes with its labels. */
    @Test
    fun statusList() {
        val statuses = fixtureStatuses("v3/statuses")
        assertEquals(listOf("To read", "Reading", "Read", "Abandoned"), statuses.map { it.name })
        assertEquals(listOf("To read", "Reading", "Finished", "Abandoned"), statuses.map { it.displayName })
        assertEquals(true, statuses.first { it.name == Status.toReadName }.isDefault)
    }

    /** A 2.14.21 catalogue still decodes, with no cover references and no labels. */
    @Test
    fun v2HasNoV3Fields() {
        val books = fixtureBooks("books")
        assertEquals(5, books.size)
        for (book in books) {
            assertNull(book.ebook?.cover)
            assertNull(book.audiobook?.cover)
            assertNull(book.readaloud?.cover)
            assertNull(book.coverReference(CoverShape.PORTRAIT))
            assertNull(book.coverReference(CoverShape.SQUARE))
            val status = book.status!!
            assertNull(status.label)
            assertEquals(status.name, status.displayName)
        }
        val statuses = fixtureStatuses("statuses")
        assertTrue(statuses.all { it.label == null && it.displayName == it.name })
    }

    /**
     * Cover references and labels survive the local store. The cache stores a
     * re-encoding of `Book`, not the server's bytes, so a field that does not
     * survive the encoder is lost on the next launch.
     */
    @Test
    fun survivesTheStore() = runBlocking {
        val books = books()
        withTemporaryDirectory("issa-v3") { directory ->
            val store = LibraryStore(serverKey = "http://storyteller.test", directory = directory)

            store.replaceCatalogue(books)
            val restored = store.allBooks()
            assertEquals(books.size, restored.size)
            for (book in books) {
                val back = restored.first { it.uuid == book.uuid }
                assertEquals(book.ebook?.cover, back.ebook?.cover)
                assertEquals(book.audiobook?.cover, back.audiobook?.cover)
                assertEquals(book.readaloud?.cover, back.readaloud?.cover)
                assertTrue(if (back.status == null) book.status == null else back.status?.label == book.status?.label)
                assertEquals(book.status?.displayName, back.status?.displayName)
            }

            val peter = restored.first { it.title == "Peter and Wendy" }
            assertEquals("Finished", peter.status?.displayName)
            assertTrue(peter.coverReference(CoverShape.SQUARE)?.sha256?.startsWith("35480043") == true)
            store.close()
        }
    }
}
