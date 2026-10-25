package com.benjaminissa.issareader.app.ui.fixture

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.Book
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import kotlinx.serialization.json.putJsonObject
import java.io.File
import java.io.RandomAccessFile

/**
 * The catalogue the layout sweep lays out: the iPhone's `FixtureLibrary`,
 * book for book, so a contact sheet from either platform shows the same
 * library.
 *
 * Deliberately awkward data, chosen for the shapes that have broken the app: a
 * title that wraps to three lines, an author list longer than the cell, a
 * description with no paragraph breaks, a book at 99%.
 */
object FixtureLibrary {
    /** The read-along book, which the sweep plants a real EPUB for. */
    const val READALONG_UUID = "11111111-1111-4111-8111-111111111111"

    private data class Row(
        val uuid: String,
        val title: String,
        val author: String,
        val progress: Double?,
        val formats: List<String>,
        /** The server's shelf name; every book carries one, so the shelves are fixed by name. */
        val status: String? = null,
        /** Drives the Recently added rail, which filters on a value being present. */
        val createdAt: String? = null,
        /** Two books share a series, so the Series rail is on screen to be measured. */
        val series: Pair<String, Double>? = null,
        /** One book carries one, so the book page's subtitle line is measured at all. */
        val subtitle: String? = null,
    )

    private val rows = listOf(
        Row(
            READALONG_UUID, "Peter and Wendy", "J. M. Barrie", 0.51, listOf("readaloud", "ebook"),
            status = "Reading", createdAt = "2026-08-30T09:00:00.000Z",
            // Barrie's own subtitle, long enough to wrap in the hero column.
            subtitle = "The Boy Who Wouldn't Grow Up",
        ),
        Row(
            "22222222-2222-4222-8222-222222222222",
            // Long enough to wrap, which is the case that broke the shelf.
            "Frankenstein; or, the Modern Prometheus", "Mary Wollstonecraft Shelley", 0.04, listOf("ebook"),
            status = "Reading", createdAt = "2026-08-28T09:00:00.000Z",
        ),
        Row(
            "33333333-3333-4333-8333-333333333333", "This Is How You Lose the Time War",
            // Two authors, which is what pushed a byline past its cover.
            "Amal El-Mohtar and Max Gladstone", null, listOf("ebook", "audiobook"),
            status = "To read", createdAt = "2026-09-01T09:00:00.000Z",
        ),
        Row(
            "44444444-4444-4444-8444-444444444444", "Dracula", "Bram Stoker",
            // Nearly finished: the bar at its widest, and "99%" not "100%".
            0.99, listOf("ebook"),
            status = "Finished", createdAt = "2026-07-04T09:00:00.000Z", series = "Gothic Horror" to 1.0,
        ),
        Row(
            "55555555-5555-4555-8555-555555555555", "Pride and Prejudice", "Jane Austen", 0.33, listOf("ebook", "readaloud"),
            status = "Reading", createdAt = "2026-08-15T09:00:00.000Z",
        ),
        Row(
            "66666666-6666-4666-8666-666666666666", "The Ballad of Songbirds and Snakes", "Suzanne Collins", null, listOf("ebook"),
            status = "To read", createdAt = "2026-08-20T09:00:00.000Z", series = "Gothic Horror" to 2.0,
        ),
    )

    /** One long paragraph with no breaks, which is what a real catalogue is full of. */
    private const val DESCRIPTION =
        "A story about people who go somewhere and find that the place is not what they were told it was, and about " +
            "what they decide to do once they know. It is long enough here to wrap several times at every width this " +
            "sweep runs at, which is the entire point of putting it in a fixture."

    /** The catalogue as the server sends it: one key per format, `series` always present. */
    val booksJson: String by lazy {
        val books: JsonArray = buildJsonArray {
            for (row in rows) {
                add(
                    buildJsonObject {
                        put("uuid", row.uuid)
                        put("title", row.title)
                        put("description", DESCRIPTION)
                        // `uuid` on every one: `Creator` and `Tag` both require
                        // it, and a nested decode failure throws the whole
                        // catalogue away.
                        putJsonArray("authors") { add(creator("${row.uuid}-aut", row.author, "aut")) }
                        putJsonArray("narrators") {
                            if ("readaloud" in row.formats) add(creator("${row.uuid}-nrt", "A Narrator", "nrt"))
                        }
                        putJsonArray("creators") {}
                        putJsonArray("tags") {
                            add(buildJsonObject { put("uuid", "tag-classics"); put("name", "Classics") })
                            add(buildJsonObject { put("uuid", "tag-fiction"); put("name", "Fiction") })
                        }
                        putJsonArray("collections") {}
                        putJsonArray("identifiers") {}
                        putJsonArray("series") {
                            row.series?.let { (name, position) ->
                                add(buildJsonObject { put("uuid", "series-$name"); put("name", name); put("position", position) })
                            }
                        }
                        row.status?.let { status -> putJsonObject("status") { put("uuid", "status-$status"); put("name", status) } }
                        row.subtitle?.let { put("subtitle", it) }
                        row.createdAt?.let { put("createdAt", it) }
                        for (format in row.formats) {
                            putJsonObject(format) {
                                put("uuid", "${row.uuid}-$format")
                                put("filepath", "${row.uuid}-$format.epub")
                                put("missing", false)
                                putJsonArray("identifiers") {}
                            }
                        }
                        row.progress?.let { progress ->
                            putJsonObject("position") {
                                putJsonObject("locator") {
                                    put("href", "OEBPS/ch01.xhtml")
                                    put("type", "application/xhtml+xml")
                                    putJsonObject("locations") {
                                        put("totalProgression", progress)
                                        put("progression", progress)
                                    }
                                }
                                put("timestamp", 1_756_000_000_000L)
                            }
                        }
                    },
                )
            }
        }
        books.toString()
    }

    const val USER_JSON = """{"id":"fixture-user","name":"Sweep","username":"sweep","permissions":{"bookList":true,"bookDownload":true,"bookRead":true}}"""

    const val EMPTY_ARRAY_JSON = "[]"

    /** The catalogue, decoded as the app decodes the server's. */
    val books: List<Book> by lazy { IssaJson.decodeFromString(ListSerializer(Book.serializer()), booksJson) }

    /**
     * Plants a file per book so the Reading tab's Downloaded section has rows
     * to lay out: a sparse file of a plausible size, so a row reads "40 MB"
     * rather than "Zero KB". The read-along book gets a small one, standing in
     * for the real EPUB the iPhone's sweep plants.
     */
    fun plantDownloads(directory: File = BookContentService.defaultDirectory()) {
        directory.mkdirs()
        for (row in rows) {
            val format = BookContentService.Format.fromRawValue(row.formats.first()) ?: continue
            val file = BookContentService.localUrl(directory, row.uuid, format)
            if (file.exists()) continue
            RandomAccessFile(file, "rw").use { it.setLength(if (row.uuid == READALONG_UUID) 20_000L else 40_000_000L) }
        }
    }

    private fun creator(uuid: String, name: String, role: String): JsonObject = buildJsonObject {
        put("uuid", uuid)
        put("name", name)
        put("role", role)
    }
}
