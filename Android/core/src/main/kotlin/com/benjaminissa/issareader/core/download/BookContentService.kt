package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.isBareUuid
import com.benjaminissa.issareader.core.model.safePathComponent
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.networking.QueryItem
import com.benjaminissa.issareader.core.networking.StorytellerError
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.NoSuchFileException

/**
 * Fetches and caches the actual book files.
 *
 * Storyteller can serve a book two ways: as a whole file, or as a Readium Web
 * Publication whose resources are fetched individually. Whole-file download is
 * what the reader wants — it is the only form that works offline, and the
 * readaloud EPUB carries its own audio inside the archive, so one download
 * yields both the text and the narration.
 *
 * @param cacheDirectory where the files go; null for [defaultDirectory]. An
 *   injected directory is a test's, and a fresh one each time, so it is
 *   prepared on the spot; the default is prepared once per process.
 */
class BookContentService(private val client: ApiClient, cacheDirectory: File? = null) {
    private val cacheDirectory: File = if (cacheDirectory != null) {
        prepare(cacheDirectory)
        cacheDirectory
    } else {
        preparedDefaultDirectory
    }

    /**
     * Which file to ask the server for. [READALOUD] is the aligned EPUB with
     * embedded audio and SMIL overlays; [EBOOK] is the plain text-only EPUB.
     */
    enum class Format(val rawValue: String) {
        EBOOK("ebook"),
        AUDIOBOOK("audiobook"),
        READALOUD("readaloud"),
        ;

        /**
         * The reader-facing name for an edition. "Read-along", never the
         * server's "Readaloud"; the other two already read plainly. Here
         * rather than on a screen because four screens say it, and two of them
         * once printed the raw value, so the app called the same edition two
         * different things.
         */
        val displayName: String
            get() = when (this) {
                EBOOK -> "Ebook"
                AUDIOBOOK -> "Audiobook"
                READALOUD -> "Read-along"
            }

        /**
         * Whether this edition is a source of the book's text. The publisher's
         * face and the question index are derived from text, which the ebook
         * and the read-along carry and an audiobook does not.
         */
        val carriesText: Boolean get() = this != AUDIOBOOK

        companion object {
            fun fromRawValue(raw: String): Format? = entries.firstOrNull { it.rawValue == raw }
        }
    }

    fun localUrl(book: Book, format: Format): File = localUrl(cacheDirectory, book.uuid, format)

    fun isDownloaded(book: Book, format: Format): Boolean = localUrl(book, format).exists()

    fun preferredReadingFormat(book: Book): Format? = Companion.preferredReadingFormat(book)

    /**
     * Downloads the file if it is not already cached, and returns its location.
     *
     * Streamed to a temporary file rather than held in memory: a readaloud
     * edition is hundreds of megabytes.
     */
    suspend fun ensureDownloaded(book: Book, format: Format): File {
        val destination = localUrl(book, format)
        if (destination.exists()) return destination

        val response = client.download(
            Endpoint.files(book.uuid),
            query = listOf(QueryItem("format", format.rawValue)),
            destination = destination,
        )
        // Judged where it landed, because the client moves it there before
        // returning. Kept, a page would count as this book from now on and be
        // refused by the reader on every open.
        val refusal = validateDownloadedFile(destination, format, response.mimeType)
        if (refusal != null) {
            destination.delete()
            IssaLog.warning(
                "downloaded file refused",
                mapOf("book" to book.uuid, "format" to format.rawValue, "type" to (response.mimeType ?: "none")),
            )
            throw StorytellerError.Download(refusal)
        }
        return destination
    }

    fun removeDownload(book: Book, format: Format) {
        removeDownload(book.uuid, format, cacheDirectory)
    }

    companion object {
        /** Prepared once per process rather than once per construction. */
        private val preparedDefaultDirectory: File by lazy { defaultDirectory().also(::prepare) }

        private fun prepare(directory: File) {
            if (!directory.isDirectory && !directory.mkdirs()) {
                // Not silent: a swallowed failure here is how a device spent
                // every session unable to save a single book while the app
                // said nothing.
                IssaLog.failure(
                    "prepare download directory",
                    IOException("Couldn't create the folder “${directory.name}”."),
                    mapOf("path" to directory.path),
                )
            }
            excludeFromBackup(directory)
        }

        /**
         * Where downloaded books live: `Books/` under [StorageRoot].
         * Re-downloadable, so kept out of backups.
         */
        fun defaultDirectory(): File = StorageRoot.directory("Books")

        /**
         * The Swift client marks the folder excluded from iCloud backup. An
         * Android app excludes paths in its backup rules rather than per
         * file, so there is nothing to do here; the call stays so the two
         * clients prepare the folder at the same points.
         */
        internal fun excludeFromBackup(@Suppress("UNUSED_PARAMETER") directory: File) = Unit

        /**
         * Moves anything left in the old caches location (`Caches/Books`).
         * Early builds wrote there; without this, an existing install silently
         * loses every download it already had.
         *
         * Guarded by [migrate]'s equality check where the caches *are* the
         * root: source and destination would be the same folder, every file
         * would be skipped as already present, and the removal at the end
         * would then delete the whole library on every launch.
         */
        fun migrateFromCachesIfNeeded() {
            migrate(File(StorageRoot.caches, "Books"), defaultDirectory())
        }

        /** The move itself, separated so it can be tested with two real directories — including the same one twice. */
        internal fun migrate(caches: File, destination: File) {
            if (!caches.exists()) return
            if (caches.canonicalFile == destination.canonicalFile) return
            destination.mkdirs()
            for (file in caches.listFiles() ?: emptyArray()) {
                val target = File(destination, file.name)
                if (!target.exists()) {
                    runCatching { Files.move(file.toPath(), target.toPath()) }
                }
            }
            caches.deleteRecursively()
            excludeFromBackup(destination)
        }

        /**
         * The one place a book's file is named.
         *
         * The identifier is checked before it names anything: `File(dir,
         * name)` neither encodes nor collapses `../`, so an unvalidated uuid
         * let a hostile or compromised server choose the path a downloaded
         * file was written to. A malformed one is hashed rather than stripped
         * ([safePathComponent]), so it cannot escape the directory and stays
         * stable, and the file is still found again afterwards.
         */
        fun localUrl(directory: File, bookUuid: String, format: Format): File =
            File(directory, "${bookUuid.safePathComponent}-${format.rawValue}.epub")

        /**
         * Whether any edition of this book that carries text is still on the
         * device: the question a removal has to ask before it releases what a
         * download left behind, since the publisher's face and the question
         * index belong to the book, not the edition. Asks the disk, because
         * the in-memory set is refreshed after the file goes.
         */
        fun hasDownloadedText(bookUuid: String, directory: File? = null): Boolean =
            downloadedFormats(bookUuid, directory).any { it.carriesText }

        /** Which of this book's editions have a file on disk. Three `stat`s at most. */
        fun downloadedFormats(bookUuid: String, directory: File? = null): Set<Format> {
            val base = directory ?: defaultDirectory()
            return Format.entries.filter { localUrl(base, bookUuid, it).exists() }.toSet()
        }

        /**
         * The best format available for reading: the aligned edition when the
         * server has one, otherwise the plain ebook.
         *
         * `missing` is honoured here rather than at each call site: an
         * audiobook-only book used to offer "Read" and dead-end in the reader,
         * and a book whose ebook the server had lost 404'd mid-download.
         */
        fun preferredReadingFormat(book: Book): Format? {
            val readaloudUsable = book.readaloud?.filepath != null && book.readaloud.missing != true
            val ebookUsable = book.ebook != null && book.ebook.missing != true
            if (readaloudUsable && book.readaloud.isAligned) return Format.READALOUD
            if (ebookUsable) return Format.EBOOK
            if (readaloudUsable) return Format.READALOUD
            return null
        }

        /**
         * Every book with at least one file on disk, from a single directory
         * read.
         *
         * **Throws rather than reporting an empty library.** The sweep
         * downstream reads "no books on disk" as "every book departed" and
         * irreversibly deletes each one's derived files. A directory this
         * cannot read is not a directory with nothing in it. A directory that
         * is *absent* really does mean an empty set — a fresh install, or
         * "sign out and delete my downloads" — so it is answered.
         */
        @Throws(IOException::class)
        fun downloadedBookUuids(directory: File? = null): Set<String> {
            val base = directory ?: preparedDefaultDirectory
            val names = try {
                Files.newDirectoryStream(base.toPath()).use { stream -> stream.map { it.fileName.toString() } }
            } catch (_: NoSuchFileException) {
                return emptySet()
            }
            return names.mapNotNull(::bookUuid).toSet()
        }

        /** The uuid a download's filename encodes, or null if it is not one of ours. */
        internal fun bookUuid(fromFilename: String): String? = decodeFilename(fromFilename)?.first

        /**
         * The book *and* the edition a download's filename encodes: the
         * inverse of [localUrl], and the only other place allowed to know the
         * shape.
         *
         * **Bare uuids only.** This is where a name found on disk becomes a
         * book id that everything downstream trusts — the orphan sweep builds
         * `Fonts/<id>/` and `Audio/<id>/` from it and deletes them whole — so
         * `..-ebook.epub`, which anybody can create, must decode to nothing.
         * It also keeps the inverse honest: [localUrl] writes `unsafe-<hash>`
         * for a malformed id, and reading that back as an id would name a
         * third file.
         */
        internal fun decodeFilename(name: String): Pair<String, Format>? {
            if (!name.endsWith(".epub")) return null
            val stem = name.removeSuffix(".epub")
            for (format in Format.entries) {
                if (!stem.endsWith("-${format.rawValue}")) continue
                val uuid = stem.dropLast(format.rawValue.length + 1)
                return if (uuid.isBareUuid) uuid to format else null
            }
            return null
        }

        /**
         * Whether a finished transfer is this edition's file, or something
         * that arrived with a 2xx in its place.
         *
         * A proxy whose session lapsed, or a captive portal, answers the file
         * route with a page of its own and a 200. Only what holds for every
         * server is checked: an EPUB is a zip and begins with `PK\u0003\u0004`;
         * nothing is assumed about an audiobook's container, only what no
         * audio ever is — a web page, an API's JSON — is refused, by the
         * declared type.
         *
         * @return null to keep the file; otherwise why it was refused, as the
         *   reader will see it.
         */
        fun validateDownloadedFile(file: File, format: Format, mimeType: String?): String? {
            when (format) {
                Format.EBOOK, Format.READALOUD -> if (beginsAsZip(file)) return null
                Format.AUDIOBOOK -> {
                    val type = mimeType?.lowercase()
                    if (type != "text/html" && type != "application/json") return null
                }
            }
            return "The server sent something other than this book. Tap to try again."
        }

        /** Whether the file starts with a zip's local file header. */
        private fun beginsAsZip(file: File): Boolean = runCatching {
            file.inputStream().use { input ->
                val header = ByteArray(4)
                var read = 0
                while (read < 4) {
                    val count = input.read(header, read, 4 - read)
                    if (count < 0) break
                    read += count
                }
                read == 4 && header.contentEquals(byteArrayOf(0x50, 0x4B, 0x03, 0x04))
            }
        }.getOrDefault(false)

        /**
         * Deletes one edition's file without needing a client — so a reader
         * signed out keeping their downloads can still remove one, and a file
         * whose book has left the catalogue can be deleted at all.
         */
        fun removeDownload(bookUuid: String, format: Format, directory: File? = null) {
            localUrl(directory ?: defaultDirectory(), bookUuid, format).delete()
        }
    }
}
