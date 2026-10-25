package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.instantOfEpochSeconds
import com.benjaminissa.issareader.core.networking.FlexibleDate
import com.benjaminissa.issareader.core.sync.LibraryService
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.descriptors.buildClassSerialDescriptor
import kotlinx.serialization.descriptors.element
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.net.URI
import java.text.DecimalFormat
import java.text.NumberFormat
import java.time.Instant
import java.util.Locale

/**
 * A book as returned by `GET /api/v2/books` and `GET /api/v2/books/{uuid}`.
 *
 * Modelled against live JSON from `web-v2.14.21` and `web-v3.0.0-beta.40`
 * servers. 3.x only adds to the shape — a cover reference on each format, a
 * `label` on each status, and a status that may be `null` — so one type decodes
 * both, and the additions are optional. Two things about the list endpoint
 * shape the whole client:
 *
 * 1. It takes no query parameters and returns the entire library in one
 *    unpaginated array. We ingest it wholesale and derive search, facets and
 *    shelves locally, which is both faster and works offline.
 * 2. It embeds this user's `position` and `status`, so a single request yields
 *    the catalogue *and* all reading progress. There is no separate progress
 *    fetch on first sync.
 *
 * The arrays and `uuid`/`title` are required, as in Swift: a book without them
 * is not a book this client can draw, and failing the decode says so.
 */
@Serializable
data class Book(
    /**
     * Stable identity. [legacyId] is a legacy integer kept for older clients;
     * always key on `uuid`.
     */
    val uuid: String,
    /** Legacy auto-increment id, kept by the server for pre-uuid clients. Never key on it. */
    @SerialName("id") val legacyId: Long? = null,

    val title: String,
    val subtitle: String? = null,
    val description: String? = null,
    val language: String? = null,
    val publicationDate: FlexibleDate? = null,

    /** Server-wide rating, distinct from this user's rating (`GET /books/{id}/rating`). */
    val rating: Double? = null,
    /** Total audio duration in seconds, when the book has audio. */
    val duration: Double? = null,
    val pageCount: Long? = null,
    val assetDir: String? = null,

    val alignedAt: FlexibleDate? = null,
    val alignedWith: String? = null,
    val alignedByStorytellerVersion: String? = null,

    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,

    // Creators are split by role server-side: `aut` and `nrt` get their own
    // arrays, and everything else (translator, editor, illustrator…) lands in
    // `creators` carrying an explicit `role`.
    val authors: List<Creator>,
    val narrators: List<Creator>,
    val creators: List<Creator>,

    val series: List<SeriesMembership>,
    val tags: List<Tag>,
    val collections: List<Collection>,
    val identifiers: List<Identifier>,
    /**
     * Ratings gathered from external sources, keyed to those identifiers.
     * Absent on servers with no external source configured.
     */
    val externalData: List<ExternalData>? = null,

    /**
     * Per-user reading status ("To read" / "Reading" / "Read"). Present only
     * when the request is authenticated.
     *
     * The server also changes this on its own when a reading position is
     * written, so a locally-set value can be superseded by simply reading on.
     * On 3.x it can also be `null` — a reader may clear it, deleting a custom
     * status clears it from every book that had it, and a library with no
     * default status never sets one — and 3.x never advances a book out of
     * that state: its position write updates a status row, and a book with no
     * status has no row to update. `StatusAdvance` is the client doing what
     * the server meant to; `LibraryArrangement.stage(of)` shelves such a book
     * where that rule would file it in the meantime — unstarted with no
     * position, "Reading" with any position short of 98%, "Read" at 98% or
     * past it.
     */
    val status: Status? = null,
    /**
     * Per-user reading position. Present only when authenticated, and `null`
     * until the book has been opened at least once.
     */
    val position: StoredPosition? = null,

    val ebook: EbookFormat? = null,
    val audiobook: AudiobookFormat? = null,
    val readaloud: ReadaloudFormat? = null,

    /**
     * Set only on a book the reader added from their own files, and never by
     * a server: `LibraryService` strips it from everything it decodes, so a
     * catalogue cannot make one of its books look like a file on this device.
     * See [LocalCopy] and [Book.Companion.local].
     *
     * A name no Storyteller version sends, so a server's own field can never
     * land here by coincidence; one sent on purpose is stripped.
     */
    @SerialName("issaLocal") val localCopy: LocalCopy? = null,
) {
    val id: String get() = uuid

    /**
     * The formats this book is actually available in. Every format the server
     * has a row for, whether or not it can serve it. For anything user-facing
     * prefer [servableFormats].
     */
    val availableFormats: Set<BookFormat>
        get() = buildSet {
            if (ebook != null) add(BookFormat.EBOOK)
            if (audiobook != null) add(BookFormat.AUDIOBOOK)
            if (readaloud != null) add(BookFormat.READALOUD)
        }

    /** True when the book has audio synchronised to its text. */
    val hasReadalong: Boolean get() = readaloud?.filepath != null

    /**
     * The formats the server can actually serve, as opposed to the rows it
     * happens to have created.
     *
     * Distinct from [availableFormats], which is a bare `!= null` check: the
     * server creates a readaloud row when alignment is merely *requested*, so
     * a book can carry one with no file behind it. A badge promising narration
     * the server cannot serve is a lie the reader only discovers after tapping.
     */
    val servableFormats: Set<BookFormat>
        get() = buildSet {
            if (ebook != null && ebook.missing != true) add(BookFormat.EBOOK)
            if (audiobook?.filepath != null && audiobook.missing != true) add(BookFormat.AUDIOBOOK)
            if (readaloud?.filepath != null && readaloud.missing != true) add(BookFormat.READALOUD)
        }

    /**
     * Whether the server can serve narration for this book: a read-along or
     * an audiobook with a file behind it that the server has not lost.
     *
     * What "With audio" means — the shelf, the count on its chip and the
     * Browse rail. They read the rows instead (`hasReadalong` or any
     * audiobook row), while the cover's mark, the Listen button and CarPlay
     * read [servableFormats], so a book whose audio row had no file sat on
     * the shelf with nothing on its screen to play.
     */
    val hasServableAudio: Boolean
        get() {
            val formats = servableFormats
            return BookFormat.READALOUD in formats || BookFormat.AUDIOBOOK in formats
        }

    /**
     * Whether opening this book leads to the reader at all. An audiobook-only
     * book has no on-screen text, so a "resume reading" request for it lands on
     * the detail screen instead — callers use this to keep that promise honest.
     */
    val isReadable: Boolean
        get() = BookFormat.EBOOK in servableFormats || BookFormat.READALOUD in servableFormats

    /** Book-level completion, 0...1, from the stored Readium locator. */
    val progress: Double? get() = position?.locator?.totalProgression

    /**
     * Adopts a position the app has just written itself.
     *
     * Refuses one older than the position already held. The server applies
     * exactly this rule to a write, and without it here a save completing out
     * of order — the mutation queue draining an earlier page after a later one
     * — makes the Continue card walk backwards.
     *
     * Swift mutates in place; a Kotlin `Book` is a value, so this returns the
     * book with the position adopted (or this one, unchanged).
     */
    fun adopting(position: ReadiumLocator, timestamp: Double): Book {
        val held = this.position
        if (held != null && held.timestamp > timestamp) return this
        return copy(position = StoredPosition(uuid = held?.uuid, locator = position, timestamp = timestamp))
    }

    /**
     * Takes everything the server says about this book except a reading
     * position older than the one already held — and, when asked, the status.
     *
     * The catalogue is refetched wholesale, and a refetch that predates a write
     * still sitting in the mutation queue carries a stale `position`. Assigning
     * it verbatim walks the Continue card — and the place the reader resumes at
     * — backwards by however long the queue has been holding.
     *
     * Title, formats, alignment, tags and page counts are all newer server
     * truth and are taken as given. The position is kept by its timestamp,
     * which the book carries. The status carries nothing to compare, so the
     * caller says whether this copy's is one the server may not hold yet.
     *
     * @param keepingStatus keep this copy's `status` over the server's. A
     *   stale status is not cosmetic when this device set it: a refresh that
     *   puts the server's older value back shows the reader a choice undone,
     *   and on 3.x an empty one invites the next position write to file the
     *   book again over what the reader chose. Whether the write is still
     *   unsent is the app's to know — the queue and the writes on their way
     *   into it — so this only applies the answer, the same way at every
     *   merge. It is applied before the position rule returns early, because
     *   a book with no position of its own can still have a status set on it.
     */
    fun reconciled(with: Book, keepingStatus: Boolean = false): Book {
        val fresh = with
        var merged = fresh
        if (keepingStatus) merged = merged.copy(status = status)
        val mine = position ?: return merged
        // A server that has never heard of our position must not clear it: the
        // write may simply not have drained yet.
        if (fresh.position?.let { mine.timestamp > it.timestamp } ?: true) {
            merged = merged.copy(position = mine)
        }
        return merged
    }

    /** Display byline. Falls back to narrators only if there is no author at all. */
    val byline: String
        get() {
            val names = if (authors.isEmpty()) narrators.map { it.name } else authors.map { it.name }
            return names.joinToString(", ")
        }

    /**
     * The series to name where there is only room for one.
     *
     * A book can belong to two — an omnibus sits in its own series and in the
     * publisher's — and a cover badge or a one-line caption has to pick one.
     * The first membership carrying a position wins, because it is the only
     * one that can say *which* book this is; an unnumbered membership is a
     * shelf label, and naming it in place of "Book 2" loses the number the
     * reader was after. Screens with room for every membership — the book
     * screen's hero — read [series] directly instead.
     */
    val primarySeries: SeriesMembership?
        get() = series.firstOrNull { it.position != null } ?: series.firstOrNull()

    /**
     * The subtitle worth putting on a screen, or null when there is none.
     *
     * The server has always sent this and the app has always kept it —
     * `LibraryStore` flattens it into the search index, which is why typing
     * "afternoon" finds *Alice's Adventures in Wonderland* — but no screen has
     * ever drawn it. In the captured `web-v2.14.21` response one of the five
     * books carries one ("A Tale for a Summer Afternoon") and the other four
     * send `null`, so both cases are ordinary.
     *
     * Trimmed to null here rather than checked with `isNotEmpty()` at the call
     * site, because the two differ on the case that shows: a subtitle of
     * `"   "` passes `isNotEmpty()`, and drawn it is an invisible line that
     * still takes a row of height and its stack's gap with it — a hole under
     * the title with nothing in it. Metadata lifted out of an EPUB carries
     * whatever whitespace the packager left around it.
     *
     * Deliberately not compared against `title`. A catalogue that repeats the
     * title as the subtitle would show it twice, but this server does not, and
     * a rule with no bug behind it is a rule nobody can check.
     */
    val displaySubtitle: String?
        get() {
            val trimmed = subtitle?.trim() ?: return null
            return trimmed.ifEmpty { null }
        }

    /**
     * How long the book's narration runs, in seconds, where it has any.
     *
     * The read-along's length first, then the audiobook's: the read-along is
     * what the reader hears in the app, and the detail badge leads with it
     * too. Five sites used to spell this chain out inline, two of them the
     * other way round, so the library sort, the widget and CarPlay could
     * disagree about the length of one book.
     */
    val narrationDuration: Double? get() = readaloud?.duration ?: audiobook?.duration

    /**
     * The 3.x cover for a shape, when the book carries a usable one.
     *
     * The same choice 3.x's own cover route makes and its web UI draws:
     * square is the audiobook's art; portrait is the ebook's, else the
     * read-along's — and an unusable ebook reference falls through to the
     * read-along's rather than ending the search.
     *
     * The one place the order is written. `LibraryService.coverData(book, …)`
     * fetches by it and the app's cover cache names its files by it, and the
     * two used to spell it out separately: a key naming one image while the
     * fetch brought back another would file the wrong art under a name that
     * looks right for as long as the cache lasts.
     *
     * null on 2.x, whose JSON has no `cover` keys, and on a row cached by
     * 1.2.0 until the next refresh: `LibraryStore` keeps a re-encoding of
     * this type rather than the server's bytes, so a field this version
     * added is absent from every older row.
     *
     * @param fallback whether a portrait with no art of its own may be
     *   answered with the square art — the uuid route's portrait-to-square
     *   404 fallback, decided from the book instead of a round trip. Ignored
     *   for a square, which the uuid route never answers with a portrait.
     */
    fun coverReference(shape: LibraryService.CoverShape, fallback: Boolean = false): CoverReference? {
        val candidates = when (shape) {
            LibraryService.CoverShape.SQUARE -> listOf(audiobook?.cover)
            LibraryService.CoverShape.PORTRAIT ->
                listOf(ebook?.cover, readaloud?.cover) + if (fallback) listOf(audiobook?.cover) else emptyList()
        }
        return candidates.firstOrNull { it != null && it.isUsable }
    }

    /**
     * Whether the book names a usable cover for either shape.
     *
     * Proof the row came from a 3.x catalogue: 2.x JSON has no `cover` keys,
     * and a row cached by 1.2.0 lost them to the re-encoding. So a book that
     * names art for one shape and not the other already carries the server's
     * answer for the other — 3.x's uuid route chooses exactly as
     * [coverReference] does and 404s where that finds nothing — and
     * `LibraryService` gives that answer without asking. Decided from the
     * book alone, so it is as right for a row held from before the refresh as
     * for a fresh one, whatever detection has or has not said.
     *
     * An unusable hash names nothing. It is never fetched, so it cannot stand
     * for the server having spoken, and such a book is asked for by uuid.
     */
    val namesAnyCover: Boolean
        get() = coverReference(LibraryService.CoverShape.PORTRAIT) != null ||
            coverReference(LibraryService.CoverShape.SQUARE) != null

    // From `Book+Membership.swift`.

    /**
     * This book's place in one named series, or null when it is not in it.
     *
     * Always by the series' name, never `series.first` or [primarySeries]:
     * an omnibus filed first under its own series and second under the
     * publisher's has two numbers, and a screen about the publisher's series
     * has to show the publisher's. The series screen, the book page's series
     * rail and `SeriesGroup.position(of)` all ask the same question, so it
     * is answered once here.
     */
    fun membership(inSeries: String): SeriesMembership? = series.firstOrNull { it.name == inSeries }

    /**
     * The book's tags with each name once, in the order the server sent them.
     *
     * A tag is identified to a reader by its name — every grouping, filter and
     * page in the app keys on it — but the server can list the same name
     * twice (two rows with different uuids, or the same row repeated). Drawn
     * as-is that is two identical chips, and a list keyed on the uuid gives
     * two cells one identity. The first of each name is kept.
     */
    val distinctTags: List<Tag>
        get() {
            val seen = mutableSetOf<String>()
            return tags.filter { seen.add(it.name) }
        }

    companion object
}

@Serializable
enum class BookFormat {
    @SerialName("ebook") EBOOK,
    @SerialName("audiobook") AUDIOBOOK,
    @SerialName("readaloud") READALOUD,
    ;

    /** Swift's raw value: `ebook`, `audiobook`, `readaloud`. */
    val rawValue: String get() = name.lowercase()
}

@Serializable
data class Creator(
    val uuid: String,
    /** Legacy auto-increment id; never key on it. */
    @SerialName("id") val legacyId: Long? = null,
    val name: String,
    /** Sort form, e.g. "Carroll, Lewis". */
    val fileAs: String? = null,
    /**
     * MARC relator code, present only in the mixed `creators` array. `aut`
     * and `nrt` are pre-split into their own arrays.
     */
    val role: String? = null,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    val id: String get() = uuid
}

@Serializable
data class SeriesMembership(
    val uuid: String,
    val name: String,
    val featured: Boolean? = null,
    /** Position within the series; fractional values are legal (e.g. 1.5 for a novella). */
    val position: Double? = null,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    val id: String get() = uuid
}

@Serializable
data class Tag(
    val uuid: String,
    val name: String,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    val id: String get() = uuid
}

@Serializable
data class Collection(
    val uuid: String,
    val name: String,
    val description: String? = null,
    @SerialName("public") val isPublic: Boolean? = null,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    val id: String get() = uuid
}

@Serializable
data class Status(
    val uuid: String,
    /**
     * What the status *is*. 2.14.21 ships exactly the three built-ins, with no
     * API to add or rename one, so there this is also what it says. 3.x keeps
     * the built-in names fixed — the server keys its own rules on them — lets
     * an admin add statuses named as they like, and puts any rewording in
     * [label], which makes this the steadier of the two to classify by.
     */
    val name: String,
    /**
     * What the status *says*, on 3.x: "Read" relabelled "Finished" still has
     * the name "Read". null on 2.x, which has no such field.
     */
    val label: String? = null,
    val isDefault: Boolean? = null,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    val id: String get() = uuid

    /**
     * What to show a reader: the label where the server has one, as its own
     * web UI does, and the name everywhere else.
     *
     * A blank label counts as none. 3.x's admin dialog accepts a label of
     * spaces and its API accepts `""`, and `label ?: name` passed either one
     * straight through: a status pill with nothing in it, a menu entry with
     * no words, and an accessibility value a screen reader reads as silence.
     * The name is always there to fall back on, as [Identifier.label] falls
     * back to its slug. A label with words in it is shown as the server sent
     * it.
     */
    val displayName: String
        get() {
            val label = label
            if (label == null || label.isBlank()) return name
            return label
        }

    companion object {
        /**
         * The three statuses a default install ships with. Compared by name
         * because the uuids are generated per-server and an admin may add
         * their own.
         */
        const val toReadName = "To read"
        const val readingName = "Reading"
        const val readName = "Read"
    }
}

@Serializable
data class Identifier(
    /**
     * The identifier *type's* uuid: the server serialises the type joined with
     * the value, so this is not unique per book.
     */
    val uuid: String? = null,
    /** Slug, e.g. `isbn-13`, `audible`, `hardcover-book-slug`. */
    val kind: String? = null,
    /** Display name, e.g. "ISBN-13", "Audible ASIN". */
    val name: String? = null,
    /** A URL with `{value}` to substitute, when the type has one configured. */
    val urlTemplate: String? = null,
    val externalSourceUuid: String? = null,
    val value: String? = null,
) {
    val id: String get() = (uuid ?: "") + (value ?: "")

    /** Where to look this identifier up, when the server knows. */
    val url: URI?
        get() {
            val template = urlTemplate ?: return null
            val value = value ?: return null
            return runCatching { URI(template.replace("{value}", value)) }.getOrNull()
        }

    /**
     * What to call this to a reader. Falls back to the slug, then to nothing:
     * a value with no label at all is worse than a slightly ugly one.
     */
    val label: String
        get() {
            if (!name.isNullOrEmpty()) return name
            if (!kind.isNullOrEmpty()) return kind.uppercase()
            return "Identifier"
        }
}

/**
 * A rating carried in from somewhere else — Hardcover, at the time of writing.
 *
 * The scale travels with the rating because sources do not agree on one: the
 * server records min and max per source precisely so a client does not have to
 * assume five stars.
 */
@Serializable
data class ExternalData(
    val uuid: String,
    val rating: Double,
    val fetchedAt: FlexibleDate? = null,
    val sourceUuid: String? = null,
    val sourceName: String? = null,
    val sourceColor: String? = null,
    val sourceUrl: String? = null,
    val sourceRatingIcon: String? = null,
    val sourceRatingMin: Double? = null,
    val sourceRatingMax: Double? = null,
) {
    val id: String get() = uuid

    /** The rating as a fraction of its own scale, for drawing it on ours. */
    val normalized: Double?
        get() {
            val low = sourceRatingMin ?: 0.0
            val high = sourceRatingMax ?: return null
            if (!(high > low)) return null
            return ((rating - low) / (high - low)).asProgression ?: 0.0
        }

    /**
     * "4.3 of 5" — stated in the source's own terms rather than converted,
     * because a reader who knows Hardcover expects Hardcover's numbers.
     *
     * In the reader's own locale, as Swift's `formatted(.number…)` is: this is
     * a number standing alone, not one embedded in English words.
     */
    val ratingText: String
        get() {
            val value = number(fractionDigits = 1).format(rating)
            val high = sourceRatingMax ?: return value
            return "$value of ${number(fractionDigits = 0).format(high)}"
        }

    private fun number(fractionDigits: Int): NumberFormat =
        NumberFormat.getNumberInstance(Locale.getDefault()).apply {
            minimumFractionDigits = 0
            maximumFractionDigits = fractionDigits
            (this as? DecimalFormat)?.roundingMode = java.math.RoundingMode.HALF_EVEN
        }
}

/** A stored reading position, as embedded in a book payload. */
@Serializable
data class StoredPosition(
    val uuid: String? = null,
    val locator: ReadiumLocator,
    /**
     * Epoch milliseconds. The server rejects a write whose timestamp is older
     * than the stored one — and also one that is *equal* with a different
     * locator — so millisecond resolution matters.
     */
    val timestamp: Double,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
) {
    /**
     * When this position was written, as an instant rather than a number.
     *
     * The trap this exists to close: [timestamp] is epoch **milliseconds**,
     * and `AudioAnchor.writtenAt` is epoch **seconds**. Both are `Double`,
     * both are named for the same idea, and comparing them directly with `>`
     * is always false for any two writes this decade — so a rule about which
     * of the two is newer would read as wired up while doing nothing at all.
     * [Instant] is the one type both can be converted into without either
     * side having to remember which unit the other chose.
     */
    val writtenAt: Instant get() = instantOfEpochSeconds(timestamp / 1000)
}

// Formats

/**
 * A 3.x cover: the content hash `/api/v2/images/{sha256}` serves it under.
 *
 * Each format carries its own, because each format has its own art — the
 * audiobook's is square. The server sends `width`, `height`, `blurhash` and
 * `colors` beside the hash; decoding ignores them, since drawing a placeholder
 * from them would be new functionality rather than parity.
 */
@Serializable(with = CoverReference.Serializer::class)
data class CoverReference(val sha256: String) {
    /**
     * Whether this is 64 lowercase hex characters, which is all the server
     * ever writes.
     *
     * The value is interpolated into a URL path and, by the app, a cache file
     * name — the same exposure that makes the catalogue refuse a uuid that is
     * not a uuid (`LibraryService.refusingUnsafeIdentifiers`). A reference
     * that fails this is treated as absent, not repaired.
     */
    val isUsable: Boolean
        get() = sha256.length == 64 && sha256.all { it in '0'..'9' || it in 'a'..'f' }

    /**
     * Decoded leniently: a `cover` that is not an object with a string
     * `sha256` becomes an unusable reference, which every reader of this type
     * already treats as no cover at all.
     *
     * Throwing would not stay local. It would fail the format, the format
     * would fail its `Book`, and one book fails the single `List<Book>` decode
     * behind `LibraryService.allBooks()` — so one reshaped cover would stop
     * the whole catalogue refreshing, where 1.2.0 ignored the key and read
     * on. beta.40 always sends a string hash, but this client follows a beta
     * line, and an unreadable cover already has an answer: the placeholder.
     * That is the opposite trade from [FlexibleDate], which throws because a
     * wrong date is silent; a missing cover is visible and costs one image.
     */
    internal object Serializer : KSerializer<CoverReference> {
        override val descriptor: SerialDescriptor =
            buildClassSerialDescriptor("com.benjaminissa.issareader.core.model.CoverReference") {
                element<String>("sha256")
            }

        override fun serialize(encoder: Encoder, value: CoverReference) {
            val json = encoder as? JsonEncoder
                ?: throw IllegalStateException("CoverReference is only written as JSON")
            json.encodeJsonElement(buildJsonObject { put("sha256", value.sha256) })
        }

        override fun deserialize(decoder: Decoder): CoverReference {
            val json = decoder as? JsonDecoder
                ?: throw IllegalStateException("CoverReference is only read from JSON")
            val element = json.decodeJsonElement()
            val sha = ((element as? JsonObject)?.get("sha256") as? JsonPrimitive)
                ?.takeIf { it.isString }?.content
            return CoverReference(sha ?: "")
        }
    }
}

@Serializable
data class EbookFormat(
    val uuid: String,
    val filepath: String? = null,
    val missing: Boolean? = null,
    val isEpub2: Boolean? = null,
    val fingerprint: String? = null,
    val pageCount: Long? = null,
    val fileSize: Long? = null,
    val identifiers: List<Identifier>,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
    /** 3.x only, and `null` when the format has no image. See [Book.coverReference]. */
    val cover: CoverReference? = null,
)

@Serializable
data class AudiobookFormat(
    val uuid: String,
    val filepath: String? = null,
    val missing: Boolean? = null,
    val fingerprint: String? = null,
    /** Seconds. */
    val duration: Double? = null,
    val fileSize: Long? = null,
    val identifiers: List<Identifier>,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
    /** 3.x only: the square art. See [Book.coverReference]. */
    val cover: CoverReference? = null,
)

/** The aligned EPUB: text plus embedded audio plus SMIL media overlays. */
@Serializable
data class ReadaloudFormat(
    val uuid: String,
    val filepath: String? = null,
    val missing: Boolean? = null,
    val isEpub2: Boolean? = null,
    /** Alignment pipeline state: CREATED, QUEUED, PROCESSING, STOPPED, ERROR, ALIGNED. */
    val status: String? = null,
    val currentStage: String? = null,
    val stageProgress: Double? = null,
    val queuePosition: Long? = null,
    val restartPending: Boolean? = null,
    val fingerprint: String? = null,
    val pageCount: Long? = null,
    val duration: Double? = null,
    val fileSize: Long? = null,
    val identifiers: List<Identifier>,
    val createdAt: FlexibleDate? = null,
    val updatedAt: FlexibleDate? = null,
    /** 3.x only. See [Book.coverReference]. */
    val cover: CoverReference? = null,
) {
    /**
     * Only an `ALIGNED` readaloud has finished the pipeline; the rest are
     * mid-flight or failed.
     *
     * Note that this is NOT sufficient to conclude the book has usable
     * narration. Observed on a real server: when the aligner cannot locate a
     * chapter's text in the transcript — which happens when the audio covers
     * only part of the book, or the spine documents are far larger than the
     * tracks — it writes the sentence markup, records `media:duration` of
     * 00:00:00, attaches no media overlays at all, and still reports ALIGNED.
     * The only trustworthy test is whether the downloaded EPUB yields a
     * non-empty timeline.
     */
    val isAligned: Boolean get() = status == "ALIGNED"
}
