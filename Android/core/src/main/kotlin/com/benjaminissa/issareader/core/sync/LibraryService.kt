package com.benjaminissa.issareader.core.sync

import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.CoverReference
import com.benjaminissa.issareader.core.model.Status
import com.benjaminissa.issareader.core.model.isBareUuid
import com.benjaminissa.issareader.core.model.roundedHalfAwayFromZero
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.QueryItem
import com.benjaminissa.issareader.core.networking.StorytellerError
import com.benjaminissa.issareader.core.toEpochSecondsDouble
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import java.text.Normalizer
import java.time.Instant

/**
 * Reads the catalogue, and the covers that go with it.
 *
 * On the 2.14.21 baseline `GET /api/v2/books` takes no parameters and returns
 * the whole library in one array, including this user's position and status.
 * The client therefore fetches once and does all searching, filtering and
 * shelf-building locally — which is faster than round-tripping and works
 * offline. On a 3.x server the same data is available piecemeal, but there is
 * no reason to prefer it, and the one array is still served whole.
 *
 * Covers are where the two generations part. 2.x serves them by book uuid;
 * 3.x keeps them by content hash under `/api/v2/images`, names that hash in
 * the book's own JSON, and answers the old uuid route with a redirect there.
 * [coverData] for a [Book] takes the direct route whenever the book says where
 * its cover is.
 */
class LibraryService(private val client: ApiClient) {
    suspend fun allBooks(): List<Book> =
        refusingUnsafeIdentifiers(client.get(Endpoint.books, ListSerializer(Book.serializer())))

    suspend fun statuses(): List<Status> = client.get(Endpoint.statuses, ListSerializer(Status.serializer()))

    @Serializable
    private data class RatingRow(val bookUuid: String? = null, val rating: Double? = null)

    /**
     * This user's ratings, as book uuid to score.
     *
     * One request for the whole library rather than one per book — the detail
     * screen and the library grid both want them.
     *
     * Each put on the five-star scale here, where it arrives: from this map a
     * rating is persisted, reloaded at every launch and handed to every
     * surface that draws stars. See [StarRating].
     */
    suspend fun myRatings(): Map<String, Double> {
        val rows = client.get(Endpoint.userRatings, ListSerializer(RatingRow.serializer()))
        val result = mutableMapOf<String, Double>()
        for (row in rows) {
            val uuid = row.bookUuid ?: continue
            val rating = row.rating?.let(StarRating::clamped) ?: continue
            result[uuid] = rating
        }
        return result
    }

    suspend fun book(uuid: String): Book = refusingUnsafeIdentifier(client.get(Endpoint.book(uuid), Book.serializer()))

    /** Storyteller keeps two covers per book: one for the text, one for the audio. */
    enum class CoverShape {
        /** The portrait ebook cover, for shelves and the book hero. */
        PORTRAIT,

        /**
         * The square audiobook cover, for the player, the media session and
         * widgets, where a portrait image would be letterboxed.
         */
        SQUARE,
    }

    /**
     * Fetches a cover by book uuid, letting the server do the resizing.
     *
     * The 2.x route, and still the one to use when there is no [Book] to hand
     * — the car can ask for a book the catalogue no longer holds. Prefer the
     * overload taking a [Book] wherever there is one: on 3.x this route is
     * deprecated and answers with a redirect, which [ApiClient.getData]
     * follows but a direct request never needs.
     *
     * Asking for the size actually needed saves both the transfer and the
     * decode: a 3 MB 2000px cover drawn into a small grid cell is most of
     * what makes a library scroll badly. [version] is the book's `updatedAt`
     * in epoch milliseconds — supplying it makes the response immutably
     * cacheable, and changes the URL when a cover is replaced.
     *
     * @param fallback whether a missing portrait cover may be answered with
     *   the square one. The default suits a shelf, where any art beats a
     *   letter tile; a caller that needs to know which shape it was given —
     *   the widget frames the two differently — turns it off and asks for the
     *   other shape itself.
     */
    suspend fun coverData(
        uuid: String,
        shape: CoverShape = CoverShape.PORTRAIT,
        pixelWidth: Int? = null,
        pixelHeight: Int? = null,
        version: Instant? = null,
        fallback: Boolean = true,
    ): ByteArray {
        val query = mutableListOf<QueryItem>()
        if (shape == CoverShape.SQUARE) query.add(QueryItem("audio", ""))
        pixelWidth?.let { query.add(QueryItem("w", it.toString())) }
        pixelHeight?.let { query.add(QueryItem("h", it.toString())) }
        version?.let { query.add(QueryItem("v", (it.toEpochSecondsDouble() * 1000).toLong().toString())) }

        return try {
            client.getData(Endpoint.cover(uuid), query)
        } catch (e: StorytellerError.NotFound) {
            if (shape != CoverShape.PORTRAIT || !fallback) throw e
            // An audiobook-only book has no text cover. Falling back is the
            // difference between artwork and a letter tile forever.
            coverData(uuid, CoverShape.SQUARE, pixelWidth, pixelHeight, version)
        }
    }

    /**
     * Fetches a book's cover by the route the book itself says to take.
     *
     * In order:
     *
     * 1. The book names a usable cover for this shape — or, for a portrait
     *    that may fall back, a square one: fetched straight from
     *    `/api/v2/images/{sha256}`. Chosen by [Book.coverReference], the
     *    function the app's cover cache names the file after, so the two
     *    cannot disagree about which image this is.
     * 2. The book names art for some shape, but not this one: `NotFound`,
     *    without a request. Only a 3.x catalogue writes cover references, so
     *    the book's silence about this shape is the server's own answer, and
     *    the deprecated uuid route would only 404. See [Book.namesAnyCover].
     * 3. The book names none: the uuid route, versioned by `updatedAt`
     *    exactly as the app has always asked for it. That is every book on
     *    2.x, asked for byte for byte as before. On 3.x it is a row cached by
     *    1.2.0, which 3.x redirects to the same image — hence `getData`
     *    following the redirect with the bearer intact — and a book that
     *    truly has no art, which costs the one request that 404s, as it did
     *    in 1.2.0.
     *
     * Nothing here asks which generation the server was detected as. That
     * says nothing about the [Book] in hand, and a book is often held from
     * before the refresh that brings its references — the one playback began
     * with, the widget's, an open reader's — and is never handed the
     * refreshed row. Answering such a book `NotFound` because the server is
     * 3.x kept the lock screen, the car, the player and the widget blank for
     * the whole session.
     *
     * The images route is sent no `v=`. Its URL is the content's own hash, so
     * a replaced cover arrives under a new URL by construction, and the
     * server marks the response immutable. `s` is the longest edge wanted:
     * the server rounds it up to its next size bucket and fits the image
     * inside, never cropping, so `max(width, height)` asks for at least what
     * either dimension needs. Omitted at zero, which the server reads as the
     * original size.
     */
    suspend fun coverData(
        book: Book,
        shape: CoverShape = CoverShape.PORTRAIT,
        pixelWidth: Int? = null,
        pixelHeight: Int? = null,
        fallback: Boolean = true,
    ): ByteArray {
        val longestEdge = maxOf(pixelWidth ?: 0, pixelHeight ?: 0)
        book.coverReference(shape, fallback)?.let { return imageData(it, longestEdge) }
        if (book.namesAnyCover) throw StorytellerError.NotFound()
        return coverData(
            uuid = book.uuid, shape = shape,
            pixelWidth = pixelWidth, pixelHeight = pixelHeight,
            version = book.updatedAt?.value, fallback = fallback,
        )
    }

    private suspend fun imageData(reference: CoverReference, longestEdge: Int): ByteArray {
        val query = if (longestEdge > 0) listOf(QueryItem("s", longestEdge.toString())) else emptyList()
        return client.getData(Endpoint.V3.image(reference.sha256), query)
    }

    companion object {
        /**
         * Drops catalogue entries whose uuid could not safely name a path.
         *
         * The boundary, so nothing downstream has to remember. A uuid reaches
         * four filesystem sinks and every `/books/{uuid}/…` route, and none of
         * that interpolation escapes anything — so one malformed entry is
         * enough to let a hostile or compromised server pick where a download
         * lands. Dropping the row loses one book from the shelf; keeping it
         * risks the app's storage.
         *
         * Logged rather than silent: a book vanishing from the library with no
         * explanation is its own support problem.
         *
         * And the boundary for `localCopy` too, which marks a book as one the
         * reader added from their own files. No server sends it; one that did
         * would have its book drawn as a file on this device, opened from a
         * folder it does not own and kept out of the account's own reset. So
         * it is dropped from every book here, whatever it says.
         */
        fun refusingUnsafeIdentifiers(books: List<Book>): List<Book> {
            val kept = ArrayList<Book>(books.size)
            for (book in books) {
                if (book.uuid.isBareUuid) {
                    kept.add(book.copy(localCopy = null))
                } else {
                    IssaLog.warning("catalogue entry refused: uuid is not a uuid", mapOf("title" to book.title))
                }
            }
            return kept
        }

        /**
         * One book, under the same two rules as the catalogue: a uuid that is
         * a uuid, and no `localCopy` — see [refusingUnsafeIdentifiers].
         */
        fun refusingUnsafeIdentifier(book: Book): Book {
            if (!book.uuid.isBareUuid) {
                IssaLog.warning("book refused: uuid is not a uuid", mapOf("title" to book.title))
                throw StorytellerError.NotFound()
            }
            return book.copy(localCopy = null)
        }
    }
}

/**
 * Derives the rails and facets the design's Library and Explore screens show.
 *
 * All of this is computed from the single catalogue fetch, which is why a 2.x
 * server loses nothing next to 3.x's server-side home sections.
 */
class LibraryDerivation(val books: List<Book>) {
    /**
     * Books with progress, most recently positioned first — the design's
     * "Continue" card and rail.
     */
    val continueReading: List<Book>
        get() = books
            .filter { (it.position?.locator?.totalProgression ?: 0.0) > 0 }
            .sortedByDescending { it.position?.timestamp ?: 0.0 }

    val readalongs: List<Book> get() = books.filter { it.hasReadalong }

    /** Author name to their books, for the design's "More by…" rail. */
    val byAuthor: Map<String, List<Book>> get() = grouped { book -> book.authors.map { it.name } }

    val byNarrator: Map<String, List<Book>> get() = grouped { book -> book.narrators.map { it.name } }

    /** Series name to its books in reading order. */
    val bySeries: Map<String, List<Book>>
        get() {
            val ordered = linkedMapOf<String, List<Book>>()
            for ((name, members) in grouped { book -> book.series.map { it.name } }) {
                // The ordinal must come from the series being grouped, not
                // `series.first`: a book in two series has two positions, and
                // ordering one series by the other's numbers shuffles it.
                ordered[name] = members.sortedBy { book ->
                    book.series.firstOrNull { it.name == name }?.position ?: Double.MAX_VALUE
                }
            }
            return ordered
        }

    /**
     * Tag name to the books that carry it, in catalogue order: the Browse
     * screen's tag rails, and anything else that lists a tag's books.
     */
    val byTag: Map<String, List<Book>> get() = grouped { book -> book.tags.map { it.name } }

    /**
     * Each name a book gives, to the books that give it — every book once.
     *
     * A catalogue row can name the same creator, series or tag twice: an
     * EPUB whose metadata repeats a `dc:creator` is enough. Grouped once per
     * mention, the book went into the group twice — two cells with one
     * identity in a rail, "3 books" for two on a series screen, another book
     * listed twice in a "More by" rail, and a tag or series on one book
     * passing the "more than one book" test for a rail of its own.
     */
    private fun grouped(names: (Book) -> List<String>): Map<String, List<Book>> {
        val groups = linkedMapOf<String, MutableList<Book>>()
        val members = mutableMapOf<String, MutableSet<String>>()
        for (book in books) {
            for (name in names(book)) {
                if (!members.getOrPut(name) { mutableSetOf() }.add(book.uuid)) continue
                groups.getOrPut(name) { mutableListOf() }.add(book)
            }
        }
        return groups
    }

    /**
     * Case- and diacritic-insensitive match across title, subtitle, authors,
     * narrators and series. The store's full-text search is what the library
     * uses; this keeps the same behaviour for a list held in memory.
     */
    fun search(query: String): List<Book> {
        val needle = query.trim()
        if (needle.isEmpty()) return books
        val folded = fold(needle)
        return books.filter { book ->
            val haystack = (listOf(book.title, book.subtitle ?: "") +
                book.authors.map { it.name } +
                book.narrators.map { it.name } +
                book.series.map { it.name }).joinToString(" ")
            fold(haystack).contains(folded)
        }
    }

    private fun fold(text: String): String =
        Normalizer.normalize(text, Normalizer.Form.NFD).replace(COMBINING_MARKS, "").lowercase()

    private companion object {
        val COMBINING_MARKS = Regex("\\p{M}+")
    }
}

/**
 * A reader's rating on the five stars there are.
 *
 * The server's rating is any `Double` — nothing stops a client, or a request
 * straight to the API, storing `1e300` — and converting that to an `Int` is
 * not a wrong answer but a trap in Swift (and a silent `Int.MAX_VALUE` here).
 * `LibraryService.myRatings()` clamps each one as it arrives, and the surfaces
 * that turn a rating into whole stars go through [wholeStars], so a value
 * persisted before the clamp is safe too.
 */
object StarRating {
    /** The scale: no stars to five. */
    val scale: ClosedFloatingPointRange<Double> = 0.0..5.0

    /** The rating on the scale, or null for one that is not a number at all. */
    fun clamped(rating: Double): Double? {
        if (!rating.isFinite()) return null
        return minOf(maxOf(rating, scale.start), scale.endInclusive)
    }

    /** Whole stars, 0 to 5, for any `Double` whatever. */
    fun wholeStars(rating: Double): Int {
        val clamped = clamped(rating.roundedHalfAwayFromZero()) ?: return 0
        return clamped.toInt()
    }
}
