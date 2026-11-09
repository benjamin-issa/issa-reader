package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.model.Book
import kotlinx.serialization.DeserializationStrategy
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * `GET /api/v2/books`, read one book at a time.
 *
 * The endpoint answers with the whole library in one array, and a `List<Book>`
 * decode is all or nothing: one row the model cannot read throws the rest
 * away. That is not a theory. `restartPending` was declared a Boolean while
 * every server sends a string during a re-alignment, so a library stopped
 * loading for as long as one book's job ran, which can be hours, and since
 * positions and statuses arrive in this same answer, nothing synced either.
 * This client follows a beta line, so the next surprise is a matter of time.
 *
 * So a row that cannot be read costs that row. It does not mean the book has
 * gone: the server listed it. [unreadable] says which books those were, and
 * whoever replaces a catalogue keeps what it already has for them
 * (`AppModel.refreshLibrary`, `LibraryStore.replaceCatalogue`).
 */
class Catalogue(val books: List<Book>, val failures: List<Failure>) {
    /**
     * A row that could not be read.
     *
     * @param uuid the book it was, if the row could at least say. Null means
     *   it could not, so nothing can be said about any book's absence from
     *   this answer: see [hasUnnamedRows].
     * @param row where in the answer it was listed, so a copy kept for it
     *   stays there.
     */
    class Failure(val uuid: String?, val error: Throwable, val row: Int)

    /** The books the server listed that this client could not read. */
    val unreadable: Set<String> get() = failures.mapNotNullTo(LinkedHashSet()) { it.uuid }

    /**
     * Whether a row could not say which book it was. One that could be any
     * book means a book missing from [books] may not have left the server.
     */
    val hasUnnamedRows: Boolean get() = failures.any { it.uuid == null }

    /** Whether this is every book the server listed. */
    val isComplete: Boolean get() = failures.isEmpty()

    /**
     * The shelf this answer makes.
     *
     * [fresh] is one book for each row that was read, in order. Around them go
     * the books held here that the answer cannot be taken to replace, each
     * back where it was listed, so a book being re-aligned does not jump to
     * the end of a grid for as long as the job runs. Those are the rows it
     * could not read. And when a row could not say which book it was, every
     * book it left out, any one of which that row could be: the same reason
     * `LibraryStore.replaceCatalogue` deletes nothing on such an answer, so
     * that the shelf and the store tell one story.
     */
    fun shelf(fresh: List<Book>, previous: List<Book>): List<Book> {
        if (failures.isEmpty()) return fresh
        val held = LinkedHashMap<String, Book>()
        for (book in previous) held.putIfAbsent(book.uuid, book)
        val shelf = fresh.toMutableList()
        val present = fresh.mapTo(HashSet()) { it.uuid }
        // A row with nothing to put back takes no place on the shelf, so the
        // rows after it sit that much earlier than the server listed them.
        var empty = 0
        for (failure in failures) {
            val uuid = failure.uuid
            val book = uuid?.takeIf { it !in present }?.let(held::get)
            if (book == null) {
                empty += 1
                continue
            }
            shelf.add(minOf(failure.row - empty, shelf.size), book)
            present += book.uuid
        }
        if (hasUnnamedRows) {
            previous.filterTo(shelf) { present.add(it.uuid) }
        }
        return shelf
    }

    /**
     * Reads the answer. A body that is not an array throws: that is not a row
     * to skip but an answer that is not a catalogue.
     */
    object Deserializer : DeserializationStrategy<Catalogue> {
        private val rows = ListSerializer(JsonElement.serializer())

        override val descriptor: SerialDescriptor get() = rows.descriptor

        override fun deserialize(decoder: Decoder): Catalogue {
            val books = ArrayList<Book>()
            val failures = ArrayList<Failure>()
            rows.deserialize(decoder).forEachIndexed { position, row ->
                try {
                    books += IssaJson.decodeFromJsonElement(Book.serializer(), row)
                } catch (e: Exception) {
                    failures += Failure(uuid(row), e, position)
                }
            }
            return Catalogue(books, failures)
        }

        /** On its own, so a row that fails as a book can still say which book it was. */
        private fun uuid(row: JsonElement): String? =
            ((row as? JsonObject)?.get("uuid") as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}
