package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.CapturedServer
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.fixture
import com.benjaminissa.issareader.core.jsonOf
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.store.LibraryStore
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.SerializationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * A row of `GET /books` this client cannot read costs that row. Ported from
 * `CatalogueTests.swift`.
 *
 * The rows below are bad in a way no server sends today, on purpose: the value
 * of this type is the next surprise, not the last one.
 */
class CatalogueTest {
    @get:Rule val temp = TemporaryFolder()

    private val uuids = listOf(
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    )

    private fun row(uuid: String, title: String = "A book"): Map<String, Any?> = bookJson(uuid, title)

    /** A book with one field the model cannot read. */
    private fun unreadableRow(uuid: String): Map<String, Any?> = row(uuid) + ("rating" to "five")

    private fun decode(rows: List<Any?>): Catalogue =
        IssaJson.decodeFromString(Catalogue.Deserializer, jsonOf(rows).toString())

    /**
     * First, middle and last, by identity. A loop that stopped at the bad row,
     * or skipped the row after it, passes a test that only looks at the count
     * or only at one position.
     */
    @Test
    fun `a bad row costs that book and no other, wherever it is`() {
        for (position in uuids.indices) {
            val rows = uuids.map { row(it) }.toMutableList()
            rows[position] = unreadableRow(uuids[position])

            val catalogue = decode(rows)

            assertEquals(uuids - uuids[position], catalogue.books.map { it.uuid })
            assertEquals(setOf(uuids[position]), catalogue.unreadable)
            assertFalse(catalogue.hasUnnamedRows)
            assertFalse(catalogue.isComplete)
        }
    }

    @Test
    fun `several bad rows in a row are all stepped over`() {
        val catalogue = decode(listOf(unreadableRow(uuids[0]), unreadableRow(uuids[1]), row(uuids[2])))
        assertEquals(listOf(uuids[2]), catalogue.books.map { it.uuid })
        assertEquals(setOf(uuids[0], uuids[1]), catalogue.unreadable)
    }

    @Test
    fun `a row that cannot say which book it was is told apart from one that can`() {
        val noUuid = row(uuids[1]) - "uuid"
        for (unnamed in listOf(noUuid, 42, "a string")) {
            val catalogue = decode(listOf(row(uuids[0]), unnamed, row(uuids[2])))
            assertEquals(listOf(uuids[0], uuids[2]), catalogue.books.map { it.uuid })
            assertTrue(catalogue.unreadable.isEmpty())
            assertTrue(catalogue.hasUnnamedRows)
        }
    }

    @Test
    fun `an empty library is a complete one`() {
        val catalogue = LibraryService.checked(decode(emptyList()))
        assertTrue(catalogue.books.isEmpty())
        assertTrue(catalogue.isComplete)
    }

    @Test
    fun `a body that is not an array is not a catalogue`() {
        assertThrows(SerializationException::class.java) {
            IssaJson.decodeFromString(Catalogue.Deserializer, """{"message": "nope"}""")
        }
    }

    /**
     * Some books the model cannot read is a shelf with gaps. No book it can
     * read is a client that no longer understands this server, which has to
     * reach the reader as an error rather than as "No books yet".
     */
    @Test
    fun `no readable row at all is an error, not an empty library`() {
        val catalogue = decode(listOf(unreadableRow(uuids[0]), unreadableRow(uuids[1])))
        assertThrows(StorytellerError.Decoding::class.java) { LibraryService.checked(catalogue) }
    }

    /**
     * Any row that can be read is worth having, with the positions and
     * statuses it carries, however many beside it cannot. Dropping the answer
     * because most of it failed stalled sync for the books that were fine.
     */
    @Test
    fun `one readable row is worth having, however many beside it are not`() {
        val catalogue = LibraryService.checked(decode(listOf(unreadableRow(uuids[0]), row(uuids[1]), unreadableRow(uuids[2]))))
        assertEquals(listOf(uuids[1]), catalogue.books.map { it.uuid })
        assertEquals(setOf(uuids[0], uuids[2]), catalogue.unreadable)
    }

    /** Weighed after the refusal, or a row refused as a book still counts as one read, and the reader is told they have no books. */
    @Test
    fun `a row refused for its uuid does not count as one that was read`() {
        val catalogue = decode(listOf(row("../../Documents/x"), unreadableRow(uuids[0])))
        assertThrows(StorytellerError.Decoding::class.java) { LibraryService.checked(catalogue) }
    }

    @Test
    fun `a uuid that could not name a path is not kept for`() {
        val catalogue = LibraryService.checked(decode(listOf(row(uuids[0]), unreadableRow("../../Documents/x"))))
        assertEquals(listOf(uuids[0]), catalogue.books.map { it.uuid })
        assertTrue(catalogue.unreadable.isEmpty())
    }

    @Test
    fun `every server's library decodes with a read-along being redone, every row of it`() {
        for (server in CapturedServer.entries) {
            val catalogue = IssaJson.decodeFromString(Catalogue.Deserializer, fixture(server.fixture("books-restarting")))
            assertTrue("$server", catalogue.isComplete)
            assertTrue("$server", catalogue.books.any { it.title == "The Gap Book" })
        }
    }

    // What a device keeps

    private fun held(): List<Book> = decode(uuids.map { row(it, title = "Here") }).books

    private fun shelf(rows: List<Any?>): List<Book> {
        val catalogue = decode(rows)
        return catalogue.shelf(catalogue.books, held())
    }

    /** First, middle and last, by identity and by place. Appended instead, a book being re-aligned jumped to the end of the grid for the whole job. */
    @Test
    fun `a book that could not be read stays where the server listed it`() {
        for (position in uuids.indices) {
            val rows = uuids.map { row(it, title = "Fresh") }.toMutableList()
            rows[position] = unreadableRow(uuids[position])

            val books = shelf(rows)

            assertEquals(uuids, books.map { it.uuid })
            assertEquals("the copy held here, not the row that failed", "Here", books[position].title)
        }
    }

    /** Counted from the raw row, the second kept book landed one place late, past the fresh book that follows it. */
    @Test
    fun `a row with no copy held here does not push the next one along`() {
        val stranger = "44444444-4444-4444-8444-444444444444"
        val catalogue = decode(listOf(unreadableRow(stranger), unreadableRow(uuids[0]), row(uuids[1]), unreadableRow(uuids[2])))
        assertEquals(uuids, catalogue.shelf(catalogue.books, held()).map { it.uuid })
    }

    @Test
    fun `what was not listed is not kept`() {
        assertEquals(listOf(uuids[0], uuids[1]), shelf(listOf(row(uuids[0]), unreadableRow(uuids[1]))).map { it.uuid })
    }

    @Test
    fun `a row that could be any book keeps every book the answer left out`() {
        assertEquals(uuids, shelf(listOf(row(uuids[0]), 42)).map { it.uuid })
    }

    /** A shelf with one uuid on it twice is a grid with one identity twice. */
    @Test
    fun `a book listed both ways is not held twice`() {
        assertEquals(listOf(uuids[0]), shelf(listOf(row(uuids[0]), unreadableRow(uuids[0]))).map { it.uuid })
    }

    @Test
    fun `a complete answer is the shelf as it stands`() {
        val catalogue = decode(uuids.reversed().map { row(it) })
        assertEquals(uuids.reversed(), catalogue.shelf(catalogue.books, held()).map { it.uuid })
    }

    // The store

    private fun withStoreHoldingEveryBook(block: suspend (LibraryStore) -> Unit) = runBlocking {
        LibraryStore(serverKey = "http://storyteller.test", directory = temp.newFolder()).use { store ->
            store.replaceCatalogue(decode(uuids.map { row(it) }).books)
            block(store)
        }
    }

    @Test
    fun `a book the server listed and this client could not read stays in the store`() = withStoreHoldingEveryBook { store ->
        val catalogue = decode(listOf(row(uuids[0]), unreadableRow(uuids[1])))
        store.replaceCatalogue(catalogue.books, keeping = catalogue.unreadable)

        assertNotNull("the unreadable book was kept", store.book(uuids[1]))
        assertNull("a book not listed has still gone", store.book(uuids[2]))
    }

    @Test
    fun `an unnamed row deletes nothing, because it could be any book`() = withStoreHoldingEveryBook { store ->
        val catalogue = decode(listOf(row(uuids[0]), 42))
        store.replaceCatalogue(catalogue.books, keeping = catalogue.unreadable, prunes = !catalogue.hasUnnamedRows)

        assertEquals(uuids.size, store.allBooks().size)
    }
}
