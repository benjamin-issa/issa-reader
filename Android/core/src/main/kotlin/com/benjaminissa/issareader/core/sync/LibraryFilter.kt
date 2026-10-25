package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.KeyValueStore
import com.benjaminissa.issareader.core.LocalizedComparison
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.orderedBy
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.descriptors.element
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray

/**
 * How the library is arranged on screen.
 *
 * Sorting and filtering happen here rather than on the server, because
 * `GET /books` on 2.14.21 takes no parameters at all — the whole catalogue
 * arrives in one response, so every arrangement of it is a local operation.
 * That is a constraint, but it is also why these are instant and work offline.
 *
 * The default is [Sort.ADDED] rather than [Sort.RECENT]: resuming a book left
 * this screen for the Reading tab, and a browse surface ordered by what you
 * last resumed was ordered by nothing a browser cares about.
 */
@Serializable(with = LibraryArrangement.Serializer::class)
data class LibraryArrangement(
    val sort: Sort = Sort.ADDED,
    val ascending: Boolean = false,
    val shelf: Shelf = Shelf.ALL,
    /** Tag names to require. Empty means no tag filter at all. */
    val tags: Set<String> = emptySet(),
) {
    enum class Sort(val rawValue: String, val title: String) {
        RECENT("recent", "Recently read"),
        TITLE("title", "Title"),
        AUTHOR("author", "Author"),
        ADDED("added", "Recently added"),
        PROGRESS("progress", "Progress"),
        DURATION("duration", "Length"),
        NARRATOR("narrator", "Narrator"),
        SERIES("series", "Series"),
        ;

        val id: String get() = rawValue

        companion object {
            fun fromRawValue(raw: String): Sort? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /** A shelf: one of the standard cuts through a library. */
    enum class Shelf(val rawValue: String, val title: String) {
        ALL("all", "All books"),
        READING("reading", "Reading"),
        TO_READ("toRead", "To read"),
        FINISHED("finished", "Finished"),
        DOWNLOADED("downloaded", "Downloaded"),
        WITH_NARRATION("withNarration", "With audio"),
        ;

        val id: String get() = rawValue

        companion object {
            fun fromRawValue(raw: String): Shelf? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    /**
     * True when anything other than the default arrangement is in force, so
     * the UI can say so rather than leaving a filtered library looking short.
     */
    val isFiltering: Boolean get() = shelf != Shelf.ALL || tags.isNotEmpty()

    /**
     * The three reading stages: the library's shelves, and the sections of
     * the tag and "More by" pages ([StagedBooks]), which are the same stages
     * rather than a copy of them.
     */
    enum class Stage { TO_READ, READING, FINISHED }

    /**
     * Writes the four fields, and reads them back field by field, with a
     * default for anything absent or unknown.
     *
     * A whole-object decoder fails the *whole* blob when one value is not
     * recognised, and [restored] falls back to a fresh arrangement on failure
     * — so adding a [Sort] case, or reading a blob written by a newer build,
     * would silently reset a reader's shelf, tags and direction along with
     * the sort. One unfamiliar value should cost one field.
     */
    internal object Serializer : KSerializer<LibraryArrangement> {
        override val descriptor: SerialDescriptor =
            buildClassSerialDescriptor("com.benjaminissa.issareader.core.sync.LibraryArrangement") {
                element<String>("sort")
                element<Boolean>("ascending")
                element<String>("shelf")
                element<List<String>>("tags")
            }

        override fun serialize(encoder: Encoder, value: LibraryArrangement) {
            val json = encoder as? JsonEncoder ?: throw IllegalStateException("LibraryArrangement is only written as JSON")
            json.encodeJsonElement(
                buildJsonObject {
                    put("sort", value.sort.rawValue)
                    put("ascending", value.ascending)
                    put("shelf", value.shelf.rawValue)
                    putJsonArray("tags") { value.tags.forEach { add(JsonPrimitive(it)) } }
                },
            )
        }

        override fun deserialize(decoder: Decoder): LibraryArrangement {
            val json = decoder as? JsonDecoder ?: throw IllegalStateException("LibraryArrangement is only read from JSON")
            val fallback = LibraryArrangement()
            val element = json.decodeJsonElement() as? JsonObject
                ?: throw SerializationException("a library arrangement is an object")
            fun string(key: String): String? = (element[key] as? JsonPrimitive)?.takeIf { it.isString }?.content
            // A string-backed case: an unrecognised one is treated as absent,
            // which is exactly the newer-build blob this guards.
            val sort = string("sort")?.let(Sort::fromRawValue) ?: fallback.sort
            val shelf = string("shelf")?.let(Shelf::fromRawValue) ?: fallback.shelf
            // The other two are as Swift's `decodeIfPresent` reads them: absent
            // or null takes the default, and a value of the wrong type is a
            // blob this build cannot read at all.
            val ascending = when (val value = element["ascending"]) {
                null, JsonNull -> fallback.ascending
                is JsonPrimitive -> value.takeIf { !it.isString }?.booleanOrNull
                    ?: throw SerializationException("ascending is not a boolean")
                else -> throw SerializationException("ascending is not a boolean")
            }
            val tags = when (val value = element["tags"]) {
                null, JsonNull -> fallback.tags
                is JsonArray -> value.map {
                    (it as? JsonPrimitive)?.takeIf { primitive -> primitive.isString }?.content
                        ?: throw SerializationException("a tag is not a string")
                }.toSet()
                else -> throw SerializationException("tags is not a list")
            }
            return LibraryArrangement(sort = sort, ascending = ascending, shelf = shelf, tags = tags)
        }
    }

    /**
     * Applies the arrangement. [isDownloaded] is injected because whether a
     * book is on disk is the app's business, not the model's.
     */
    fun apply(books: List<Book>, isDownloaded: (Book) -> Boolean = { false }): List<Book> {
        var filtered = books.filter { book ->
            when (shelf) {
                Shelf.ALL -> true
                Shelf.READING -> stage(book) == Stage.READING
                Shelf.TO_READ -> stage(book) == Stage.TO_READ
                Shelf.FINISHED -> stage(book) == Stage.FINISHED
                Shelf.DOWNLOADED -> isDownloaded(book)
                Shelf.WITH_NARRATION -> book.hasServableAudio
            }
        }
        if (tags.isNotEmpty()) {
            // Every selected tag must be present: narrowing, not widening,
            // which is what a reader means by picking a second tag.
            filtered = filtered.filter { book -> book.tags.map { it.name }.toSet().containsAll(tags) }
        }
        return sorted(filtered)
    }

    /**
     * Writes the arrangement where [restored] reads it. Reading it here rather
     * than in the app model keeps the key and the shape in one place — the two
     * have to agree, and they drift when they are apart.
     */
    fun store(defaults: KeyValueStore) {
        val data = runCatching { IssaJson.encodeToString(serializer(), this) }.getOrNull() ?: return
        defaults.putString(STORAGE_KEY, data)
    }

    private fun sorted(books: List<Book>): List<Book> {
        val ordered: List<Book> = when (sort) {
            Sort.RECENT ->
                // Books never opened have no position and belong at the end
                // whichever way the sort runs, not interleaved with recent
                // reads — so the direction lives in the comparator, where it
                // flips only the timestamps. The blanket reversal below would
                // flip the never-opened block to the top of the shelf.
                return books.sortedWith(
                    orderedBy { left, right ->
                        val l = left.position?.timestamp
                        val r = right.position?.timestamp
                        when {
                            l != null && r != null -> if (ascending) l < r else l > r
                            l == null && r != null -> false
                            l != null && r == null -> true
                            else -> false
                        }
                    },
                )
            Sort.TITLE ->
                // The same locale-aware comparison `AUTHOR` uses: a code-unit
                // comparison files every accented initial after Z — Émile
                // ended up behind Zorro.
                books.sortedWith(LocalizedComparison.comparing { sortKey(it.title) })
            Sort.AUTHOR -> books.sortedWith(LocalizedComparison.comparing { it.authors.firstOrNull()?.fileAs ?: it.byline })
            Sort.ADDED ->
                // Books the server never dated go last either way, the rule
                // `RECENT` and `NARRATOR` follow: this is the default sort
                // now, and the blanket reversal below would have put every
                // undated book ahead of the newest arrival.
                return books.sortedWith(
                    orderedBy { left, right ->
                        val l = left.createdAt?.value
                        val r = right.createdAt?.value
                        when {
                            l != null && r != null -> if (ascending) l < r else l > r
                            l == null && r != null -> false
                            l != null && r == null -> true
                            else -> false
                        }
                    },
                )
            Sort.PROGRESS -> books.sortedByDescending { it.progress ?: 0.0 }
            Sort.DURATION -> books.sortedByDescending { duration(it) }
            Sort.NARRATOR ->
                // Books with no narrator sort last either way, the same rule
                // `RECENT` uses for books never opened — and, like `RECENT`,
                // the direction lives in the comparator so the reversal below
                // cannot move that bucket to the front.
                return books.sortedWith(
                    orderedBy { left, right ->
                        val l = left.narrators.firstOrNull()?.let { it.fileAs ?: it.name }
                        val r = right.narrators.firstOrNull()?.let { it.fileAs ?: it.name }
                        when {
                            l != null && r != null ->
                                LocalizedComparison.compare(l, r) == (if (ascending) 1 else -1)
                            l == null && r != null -> false
                            l != null && r == null -> true
                            else -> false
                        }
                    },
                )
            Sort.SERIES ->
                // Standalone books sort after every series either way, the
                // rule `RECENT` and `NARRATOR` follow for the bucket that has
                // nothing to compare — so the direction lives in the
                // comparator, and the blanket reversal below cannot lift a
                // library's unseried majority above the sequences this sort
                // exists to show.
                return books.sortedWith(orderedBy { left, right -> inSeriesOrder(left, right, ascending) })
        }
        return if (ascending) ordered.reversed() else ordered
    }

    companion object {
        const val STORAGE_KEY = "issa.library.arrangement"
        const val SORT_MIGRATION_KEY = "issa.library.arrangement.sortMigrated"

        /**
         * The arrangement the reader last chose, or the default.
         *
         * The default used to be "Recently read", and every reader who never
         * opened the sort menu has that stored. Flip it to the new default
         * once; a reader who picks "Recently read" after this keeps it. A
         * reader who chose it *before* this build loses it this one time — a
         * stored `recent` cannot say whether it was chosen or inherited. The
         * flag is set on every path, including a fresh install with no blob
         * yet, so a later deliberate choice is never mistaken for the
         * inherited one.
         */
        fun restored(defaults: KeyValueStore): LibraryArrangement {
            val migrate = !defaults.getBoolean(SORT_MIGRATION_KEY)
            try {
                val data = defaults.getString(STORAGE_KEY) ?: return LibraryArrangement()
                var value = runCatching { IssaJson.decodeFromString(serializer(), data) }.getOrNull()
                    ?: return LibraryArrangement()
                if (migrate && value.sort == Sort.RECENT) {
                    value = value.copy(sort = LibraryArrangement().sort)
                    value.store(defaults)
                }
                return value
            } finally {
                defaults.putBoolean(SORT_MIGRATION_KEY, true)
            }
        }

        /**
         * Which of the three reading stages a book is in.
         *
         * A book with a status is shelved by the status's name,
         * [stage] of a name.
         *
         * A book with *no* status is shelved where the server's own rule files
         * a book once a position is written for it. With no position it is
         * unstarted. With one — any one, 0% and a locator with no progression
         * included — it is shelved under the built-in status
         * [StatusAdvance.builtInStatusName] names: "Read" at 98% or more,
         * "Reading" short of that. That is the function [StatusAdvance] files a
         * book with, so the shelf cannot disagree with the write. It did while
         * the shelf read the progress itself: a book at 0% stayed on "To read"
         * here, where the server's rule and this device's write both put it on
         * "Reading".
         *
         * 2.x never sends a book without a status: it gives every book a status
         * row for every reader — adding a book writes one per user, adding a
         * user one per book, and a migration backfilled any gap. 3.x does send
         * one, and never moves it — its position write updates a status row
         * the book does not have — so a book read to the end in the web reader
         * would otherwise sit on "To read" forever. This files it where 2.x
         * would have. Display only: nothing is written back; [StatusAdvance]
         * does that for positions this device writes.
         */
        fun stage(book: Book): Stage {
            book.status?.let { return stage(statusNamed = it.name) }
            val locator = book.position?.locator ?: return Stage.TO_READ
            return stage(statusNamed = StatusAdvance.builtInStatusName(locator))
        }

        /**
         * Which of the three reading stages a status of this name is.
         *
         * This matches the status name loosely rather than against a fixed
         * vocabulary. 2.14.21 ships exactly the three built-ins, with no API to
         * add or rename one, so there the looseness is only defensive; 3.x lets
         * an admin add statuses of their own, which it files by their wording
         * where that says a stage. It reads `name`, never `label`: 3.x fixes
         * the built-in names and puts an admin's wording in the label, so
         * "Read" relabelled "Finished" is still named "Read".
         *
         * The bare word "read" says finished only when nothing beside it says
         * otherwise. It used to say it whatever surrounded it, so "Read later",
         * "Not read" and "Re-read" all filed books under Finished, off Up next
         * and Reading. In order:
         *
         * 1. Put off or turned around — "To read", "Read later", "Up next",
         *    "Not read", "Never finished", "Unread", "Did not finish": to read.
         * 2. Again or in part — "Re-read", "Half read", "Partially read":
         *    reading.
         * 3. Said to be over — "Finished", "Finished reading", "Done",
         *    "Completed": finished, ahead of the "reading" in the longer ones.
         * 4. "Reading", "Currently reading", "In progress": reading.
         * 5. "Read" with nothing to qualify it — "Read", "Already read":
         *    finished.
         *
         * Anything else ("Abandoned", "Reference", "DNF") is none of the three,
         * and unstarted is the least wrong place for it.
         */
        fun stage(statusNamed: String): Stage {
            val name = statusNamed.lowercase()
            if (name.isEmpty()) return Stage.TO_READ
            // Whole words for the short ones, substrings only for the phrases.
            // "Abandoned" contains "done", so a reader who abandoned a book
            // found it filed under Finished. Split on anything not a letter, so
            // "Re-read" and "Half-read" are two words each.
            val words = words(name)
            fun says(word: String) = word in words

            val putOff = "to read" in name || "not started" in name ||
                says("later") || says("next") || says("want")
            val turnedAround = says("not") || says("never") || says("un") ||
                words.any { it.startsWith("un") && it.drop(2) in stageWords }
            if (putOff || turnedAround) return Stage.TO_READ

            val readWords = says("read") || says("reading")
            val again = (says("re") && readWords) || says("reread") || says("rereading") || (says("again") && readWords)
            val inPart = says("half") || says("partially") || says("partly")
            if (again || inPart) return Stage.READING

            if (says("finished") || says("done") || says("completed") || says("complete")) return Stage.FINISHED
            if (says("reading") || "in progress" in name) return Stage.READING
            if (says("read")) return Stage.FINISHED
            return Stage.TO_READ
        }

        /** The runs of letters in [text]. */
        private fun words(text: String): Set<String> {
            val words = mutableSetOf<String>()
            val current = StringBuilder()
            for (char in text) {
                if (char.isLetter()) {
                    current.append(char)
                } else if (current.isNotEmpty()) {
                    words.add(current.toString())
                    current.clear()
                }
            }
            if (current.isNotEmpty()) words.add(current.toString())
            return words
        }

        /**
         * What follows "un" in a status that turns a stage around: "Unread",
         * "Unfinished", "Unstarted".
         */
        private val stageWords: Set<String> = setOf("read", "reading", "finished", "started", "done", "completed")

        /**
         * Reading order across a whole shelf: series first, each in its own
         * order, standalone books after them.
         *
         * Its own function because the rule is three comparisons deep — series
         * name, then position within it, then title — and each has to flip with
         * the direction while the two buckets that carry no value at all, an
         * unnumbered book and an unseried one, stay where they are.
         */
        fun inSeriesOrder(left: Book, right: Book, ascending: Boolean): Boolean {
            // The same spelling `NARRATOR` uses: a comparison that reads
            // forward is ascending unless the reader asked for the reverse.
            val forward = if (ascending) 1 else -1
            val l = left.primarySeries
            val r = right.primarySeries
            when {
                l != null && r != null -> {
                    val byName = LocalizedComparison.compare(l.name, r.name)
                    if (byName != 0) return byName == forward
                    val lp = l.position
                    val rp = r.position
                    when {
                        lp != null && rp != null && lp != rp -> return if (ascending) lp > rp else lp < rp
                        // A book the server never numbered has no place in the
                        // run, so it sits after the numbered ones whichever way
                        // the series is read.
                        lp == null && rp != null -> return false
                        lp != null && rp == null -> return true
                        // Same series, same position, or neither numbered: the
                        // title decides, below.
                        else -> Unit
                    }
                }
                l == null && r != null -> return false
                l != null && r == null -> return true
                else -> Unit
            }
            return LocalizedComparison.compare(sortKey(left.title), sortKey(right.title)) == forward
        }

        fun duration(book: Book): Double = book.narrationDuration ?: 0.0

        /**
         * Sorting titles the way a shelf does: leading articles ignored, so
         * *The Time Machine* files under T for Time.
         */
        fun sortKey(title: String): String {
            val lowered = title.lowercase()
            for (article in listOf("the ", "a ", "an ")) {
                if (lowered.startsWith(article)) return lowered.drop(article.length)
            }
            return lowered
        }
    }
}
