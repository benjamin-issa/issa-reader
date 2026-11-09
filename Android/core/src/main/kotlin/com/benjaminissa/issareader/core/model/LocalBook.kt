package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.SwiftDateSerializer
import com.benjaminissa.issareader.core.networking.FlexibleDate
import com.benjaminissa.issareader.core.networking.StorytellerDate
import kotlinx.serialization.Serializable
import java.io.File
import java.time.DateTimeException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset

/**
 * What makes a [Book] one the reader added from their own files.
 *
 * Carried on the book itself ([Book.localCopy]) and stored with it in the
 * device store, so everything the list and Book info show about the copy
 * survives a relaunch without a second table. A server never sends this:
 * `LibraryService` strips it from every book it decodes.
 *
 * Built with the [LocalCopy] function that takes `notices`, as Swift's
 * initialiser does; this constructor takes the raw values a decoder reads.
 */
@Serializable
data class LocalCopy(
    /** The name the file had where the reader chose it, for Book info and for "Choose emma.epub again". */
    val fileName: String,
    /**
     * SHA-256 of the EPUB's bytes, lowercase hex. Matches a second import of
     * the same file, and a file added again after a restore.
     */
    val fingerprint: String,
    /** The size of the copy, in bytes. */
    val byteCount: Long,
    @Serializable(with = SwiftDateSerializer::class) val importedAt: Instant,
    /** When the reader last opened it; the list is ordered by this. */
    @Serializable(with = SwiftDateSerializer::class) val lastOpenedAt: Instant? = null,
    /** Whether a `cover.jpg` was cut from the book at import. */
    val hasCover: Boolean = false,
    /**
     * The package's unique identifier, which matches a book whose bytes have
     * changed — a fresh download of the same edition — before the hash would.
     */
    val packageIdentifier: String? = null,
    /** The package version the book declares: "2.0", "3.0". */
    val epubVersion: String? = null,
    /** Laid out as fixed pages, which this reader shows as flowing text. */
    val isFixedLayout: Boolean = false,
    /**
     * The notices still owed to the reader, as raw values.
     *
     * Strings rather than [LocalNotice]s: a notice a later build adds must not
     * make this build fail to decode the whole book — and with it the reader's
     * place and the row itself. Unknown values are kept and ignored.
     */
    val noticeValues: List<String> = emptyList(),
) {
    /** The notices this build knows how to show, in the order they were raised. */
    val notices: List<LocalNotice> get() = noticeValues.mapNotNull { LocalNotice.fromRawValue(it) }

    /**
     * This copy with [notices] in place of the known ones.
     *
     * Keeps whatever this build cannot read, so a newer build's notice
     * outlives a round trip through this one. (Swift's `notices` setter.)
     */
    fun withNotices(notices: List<LocalNotice>): LocalCopy {
        val unknown = noticeValues.filter { LocalNotice.fromRawValue(it) == null }
        return copy(noticeValues = notices.map { it.rawValue } + unknown)
    }

    /** Whether the book is EPUB 2, which can carry no narration. */
    val isEpub2: Boolean get() = epubVersion?.startsWith("2") ?: false
}

/** Swift's `LocalCopy.init(…, notices:)`: a copy carrying the notices given. */
fun LocalCopy(
    fileName: String,
    fingerprint: String,
    byteCount: Long,
    importedAt: Instant,
    lastOpenedAt: Instant? = null,
    hasCover: Boolean = false,
    packageIdentifier: String? = null,
    epubVersion: String? = null,
    isFixedLayout: Boolean = false,
    notices: List<LocalNotice>,
): LocalCopy = LocalCopy(
    fileName = fileName,
    fingerprint = fingerprint,
    byteCount = byteCount,
    importedAt = importedAt,
    lastOpenedAt = lastOpenedAt,
    hasCover = hasCover,
    packageIdentifier = packageIdentifier,
    epubVersion = epubVersion,
    isFixedLayout = isFixedLayout,
    noticeValues = notices.map { it.rawValue },
)

/**
 * Something worth telling the reader once about a book that was added.
 *
 * Information only: the book was added and opens normally. Shown on the
 * book's row until the reader dismisses it.
 */
enum class LocalNotice(val rawValue: String) {
    /**
     * The book has narration whose audio this device cannot play, so it was
     * added as text only.
     */
    NARRATION_UNPLAYABLE("narrationUnplayable"),

    /** The book was designed as fixed pages and is shown as flowing text. */
    FIXED_LAYOUT("fixedLayout"),
    ;

    companion object {
        fun fromRawValue(raw: String): LocalNotice? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * Where one local book's files live: `Local/<uuid>/`.
 *
 * Everything the book creates — the copy, its cover, the narration extracted
 * on first open and the publisher's face — is under this one folder, so
 * removing the book is removing the folder, and nothing that sweeps the
 * server's downloads (`Books/`, `Audio/`, `Fonts/<uuid>/`) can reach it.
 *
 * @param root the `Local` folder; a test passes a temporary one.
 */
data class LocalBookFiles(val bookUuid: String, private val root: File? = null) {
    /**
     * The book's folder. [safePathComponent], as every other per-book folder:
     * this one is deleted whole when the book is removed.
     */
    val folder: File = File(root ?: defaultRoot, bookUuid.safePathComponent)

    /** The copy of the EPUB. */
    val epub: File get() = File(folder, "book.epub")

    /** The cover cut from the EPUB at import, at most 1200 px. */
    val cover: File get() = File(folder, "cover.jpg")

    /** The narration, extracted on first open. */
    val narration: File get() = File(folder, "Audio")

    /** The publisher's face, extracted on open. */
    val fonts: File get() = File(folder, "Fonts")

    companion object {
        /**
         * `StorageRoot/Local`, kept out of backups by whoever creates it — the
         * original is still where the reader chose it from.
         */
        val defaultRoot: File get() = StorageRoot.directory("Local")

        /** Where copies wait while they are checked, before they have a book. */
        fun incoming(root: File? = null): File = File(root ?: defaultRoot, ".incoming")
    }
}

/**
 * What an EPUB says about itself, in the shape [Book.Companion.local] needs.
 *
 * Built by the EPUB module's `localMetadata(fallbackTitle)`. Kept here rather
 * than in the EPUB module so the factory needs nothing but this one.
 */
data class LocalBookMetadata(
    val title: String,
    val subtitle: String? = null,
    val description: String? = null,
    val language: String? = null,
    val publisher: String? = null,
    /** `dc:date` as written. */
    val date: String? = null,
    val authors: List<LocalContributor> = emptyList(),
    val narrators: List<LocalContributor> = emptyList(),
    /** Everyone else — translators, illustrators, editors — with their role. */
    val creators: List<LocalContributor> = emptyList(),
    val series: LocalSeries? = null,
    val identifier: String? = null,
) {
    companion object {
        /**
         * `dc:date` as books write it — a timestamp, a day, a month or a bare
         * year — as the start of the period it names, in UTC.
         */
        fun parseDate(raw: String): Instant? {
            val text = raw.trim()
            StorytellerDate.parse(text)?.let { return it }
            val parts = text.split('-')
            if (parts.size !in 1..3) return null
            if (!parts.all { part -> part.isNotEmpty() && part.all { it in '0'..'9' } }) return null
            if (parts[0].length != 4) return null
            val numbers = parts.map { it.toIntOrNull() ?: return null }
            return try {
                LocalDate.of(
                    numbers[0],
                    if (numbers.size > 1) numbers[1] else 1,
                    if (numbers.size > 2) numbers[2] else 1,
                ).atStartOfDay(ZoneOffset.UTC).toInstant()
            } catch (_: DateTimeException) {
                null
            }
        }
    }
}

data class LocalContributor(
    val name: String,
    val fileAs: String? = null,
    /** The MARC relator code, when the book gave one. */
    val role: String? = null,
)

data class LocalSeries(
    val name: String,
    val position: Double? = null,
)

/** Whether this book came from the reader's own files rather than a server. */
val Book.isLocal: Boolean get() = localCopy != null

/**
 * The one way to make a [Book] that no server sent.
 *
 * A `Book` is otherwise only ever decoded, so a book from the reader's files
 * is built here, from what its EPUB says.
 *
 * A book with narration the device can play carries a `readaloud` with
 * status ALIGNED and its length, which is what `hasReadalong`,
 * `narrationDuration` and the position guard's tolerance read; any other book
 * carries an `ebook` only. Both name `book.epub`, the copy's name in its
 * folder. `createdAt` is the import.
 *
 * @param uuid a fresh lowercase uuid per import — never the EPUB's own
 *   identifier, which two different books can share and which can be
 *   anything at all.
 */
fun Book.Companion.local(
    uuid: String,
    metadata: LocalBookMetadata,
    narrationDuration: Double?,
    copy: LocalCopy,
): Book {
    fun creators(people: List<LocalContributor>, kind: String): List<Creator> =
        people.mapIndexed { index, person ->
            Creator(uuid = "$uuid-$kind$index", name = person.name, fileAs = person.fileAs, role = person.role)
        }
    val filepath = "book.epub"
    val imported = FlexibleDate(copy.importedAt)
    val narrated = narrationDuration?.let { it > 0 } ?: false
    return Book(
        uuid = uuid,
        title = metadata.title,
        subtitle = metadata.subtitle,
        description = metadata.description,
        language = metadata.language,
        publicationDate = metadata.date?.let { LocalBookMetadata.parseDate(it) }?.let { FlexibleDate(it) },
        duration = if (narrated) narrationDuration else null,
        createdAt = imported,
        updatedAt = imported,
        authors = creators(metadata.authors, "a"),
        narrators = creators(metadata.narrators, "n"),
        creators = creators(metadata.creators, "c"),
        series = metadata.series?.let { listOf(SeriesMembership(uuid = "$uuid-s0", name = it.name, position = it.position)) }
            ?: emptyList(),
        tags = emptyList(),
        collections = emptyList(),
        identifiers = emptyList(),
        ebook = if (narrated) {
            null
        } else {
            EbookFormat(
                uuid = "$uuid-ebook", filepath = filepath,
                isEpub2 = copy.isEpub2, fileSize = copy.byteCount, identifiers = emptyList(),
            )
        },
        readaloud = if (narrated) {
            ReadaloudFormat(
                uuid = "$uuid-readaloud", filepath = filepath, status = "ALIGNED",
                duration = narrationDuration, fileSize = copy.byteCount, identifiers = emptyList(),
            )
        } else {
            null
        },
        localCopy = copy,
    )
}
