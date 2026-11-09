package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.StorageRoot
import com.benjaminissa.issareader.core.model.Book
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

/**
 * What is on this device, grouped the way every downloads surface draws it.
 *
 * Deliberately split in two. [invoke] (and [make]) is pure — it is *handed*
 * the sizes rather than reading them — so the grouping, the ordering and the
 * arithmetic are testable without a filesystem; [scan] is the thin layer that
 * walks the disk and hands the result to it. Both halves once lived inside a
 * screen no test could reach, which is why the storage bar could be wrong for
 * a whole release and nothing said so.
 */
data class DownloadsInventory(
    /** Every downloaded edition, largest first. */
    val items: List<DownloadedItem>,
    /** Bytes per format, for the storage bar's bands. */
    val byFormat: Map<BookContentService.Format, Long>,
    /**
     * Bytes in the Books directory that no row above accounts for: almost
     * always a download whose book has left the catalogue. [orphans] is the
     * deletable subset of them.
     */
    val unaccountedBytes: Long,
    /**
     * The unaccounted files this app can still name, so a sweep has something
     * to act on. Anything in the directory that is not one of our filenames
     * counts towards [unaccountedBytes] and is deliberately left alone.
     */
    val orphans: List<FileKey>,
    /**
     * What a sweep of [orphans] would actually reclaim, and nothing else:
     * strictly no larger than [unaccountedBytes], so the promise and the
     * action are the same figure.
     */
    val orphanBytes: Long,
    val extractedAudioBytes: Long,
    val coverBytes: Long,
    val publisherFontBytes: Long,
    val askIndexBytes: Long,
    val freeBytes: Long,
    /** The Books directory as a whole — rows plus [unaccountedBytes]. */
    val bookFileBytes: Long,
) {
    /** One downloaded edition: which book, which format, how big. */
    data class DownloadedItem(val book: Book, val format: BookContentService.Format, val bytes: Long) {
        /**
         * Book *and* format: one book can have a read-along and a plain ebook
         * on the device at once, and they are two rows with two sizes and two
         * delete buttons.
         */
        val id: String get() = "${book.uuid}-${format.rawValue}"
    }

    /** One file in the Books directory, identified the way this app names them. */
    data class FileKey(val bookUuid: String, val format: BookContentService.Format) : Comparable<FileKey> {
        /** Only so a sweep and a test both get the same order out of a map, which has none. */
        override fun compareTo(other: FileKey): Int =
            compareValuesBy(this, other, { it.bookUuid }, { it.format.rawValue })
    }

    /**
     * The disk figures, before any of them have been matched to a book. A
     * class rather than eight parameters, so a test can state one field and
     * default the rest.
     */
    data class Sizes(
        /** Every file in the Books directory this app can name, with its size. */
        val files: Map<FileKey, Long> = emptyMap(),
        /** The whole Books directory, including files no book in the catalogue claims. */
        val booksDirectoryBytes: Long = 0,
        /** Narration extracted from a read-along for playback. */
        val extractedAudioBytes: Long = 0,
        /** The cover cache. */
        val coverBytes: Long = 0,
        /**
         * Faces extracted from books — `Fonts/<book-uuid>/` only. Faces the
         * reader imported sit at the root of `Fonts/` and are theirs.
         */
        val publisherFontBytes: Long = 0,
        /** The question indexes, one SQLite file per book: the largest derived store this app keeps. */
        val askIndexBytes: Long = 0,
        /** Room left on the volume, or 0 where the platform will not say. */
        val freeBytes: Long = 0,
    )

    /** How much of the disk [scan] walks. */
    enum class Scope {
        /** The Books directory alone: one directory read, no recursion. What the Reading tab's section asks for. */
        BOOKS_ONLY,

        /** Everything the storage bar reports, recursive walks included. */
        EVERYTHING,
    }

    /** Everything this app is using, which is what the headline reports. */
    val totalBytes: Long get() = bookFileBytes + extractedAudioBytes + coverBytes + publisherFontBytes + askIndexBytes

    /** The rows' own total — "4 books · 1.4 GB" counts these, not the caches. */
    val itemBytes: Long get() = bytes(items)

    val isEmpty: Boolean get() = items.isEmpty()

    /** How many distinct books, which is what the reader counts. Two editions of one book are one book. */
    val bookCount: Int get() = bookCount(items)

    companion object {
        val empty: DownloadsInventory by lazy { DownloadsInventory(books = emptyList(), downloaded = emptySet(), sizes = Sizes()) }

        /** The number of books among [items], for a screen showing a subset of the rows. */
        fun bookCount(items: List<DownloadedItem>): Int = items.map { it.book.uuid }.toSet().size

        fun bytes(items: List<DownloadedItem>): Long = items.sumOf { it.bytes }

        /**
         * Groups a set of files on disk into rows, in one pass and with no I/O.
         *
         * Bounded by what is actually on the device, not by the library:
         * [downloaded] is the set the download engine already keeps, so a
         * library of a thousand books whose owner has kept three costs three
         * lookups. That bound is load-bearing.
         *
         * @param books the catalogue.
         * @param downloaded the uuids with at least one file on disk.
         * @param sizes what the disk holds, from [scan] or from a test.
         */
        operator fun invoke(books: List<Book>, downloaded: Set<String>, sizes: Sizes): DownloadsInventory {
            val found = mutableListOf<DownloadedItem>()
            val totals = mutableMapOf<BookContentService.Format, Long>()
            for (book in books) {
                if (book.uuid !in downloaded) continue
                for (format in BookContentService.Format.entries) {
                    val bytes = sizes.files[FileKey(book.uuid, format)] ?: continue
                    found.add(DownloadedItem(book, format, bytes))
                    totals[format] = (totals[format] ?: 0) + bytes
                }
            }

            // Largest first, because the question this screen answers is "what
            // is taking up the room". Title and format break ties so the order
            // is the same on every run.
            val items = found.sortedWith(
                compareByDescending<DownloadedItem> { it.bytes }.thenBy { it.book.title }.thenBy { it.format.rawValue },
            )

            val known = books.map { it.uuid }.toSet()
            val unclaimed = sizes.files.keys.filter { it.bookUuid !in known }.sorted()
            return DownloadsInventory(
                items = items,
                byFormat = totals,
                // Clamped: the directory total and the per-file sizes are two
                // reads of a directory a transfer may have written to in
                // between, and a negative band would draw the bar the wrong way.
                unaccountedBytes = maxOf(0, sizes.booksDirectoryBytes - found.sumOf { it.bytes }),
                orphans = unclaimed,
                orphanBytes = unclaimed.sumOf { sizes.files[it] ?: 0 },
                extractedAudioBytes = sizes.extractedAudioBytes,
                coverBytes = sizes.coverBytes,
                publisherFontBytes = sizes.publisherFontBytes,
                askIndexBytes = sizes.askIndexBytes,
                freeBytes = sizes.freeBytes,
                bookFileBytes = sizes.booksDirectoryBytes,
            )
        }

        /** The same thing spelled as a function, which is how the call sites read. */
        fun make(books: List<Book>, downloaded: Set<String>, sizes: Sizes): DownloadsInventory =
            invoke(books, downloaded, sizes)

        /**
         * The books that lost their *last* file between two readings of the
         * disk: what a reconciliation sweep asks. A book with two editions
         * that loses one has not departed, and deleting its derived files
         * because one edition went would be wrong.
         */
        fun departed(previous: Set<String>, current: Set<String>): Set<String> = previous - current

        /**
         * Walks the disk and groups what it finds, off the caller's thread.
         * One directory read for both the per-file sizes and the total;
         * non-recursive, because downloads are flat files.
         */
        suspend fun scan(
            books: List<Book>,
            downloaded: Set<String>,
            scope: Scope = Scope.EVERYTHING,
            booksDirectory: File? = null,
        ): DownloadsInventory = withContext(Dispatchers.IO) {
            val directory = booksDirectory ?: BookContentService.defaultDirectory()
            val files = mutableMapOf<FileKey, Long>()
            var booksDirectoryBytes = 0L
            for (entry in directory.listFiles() ?: emptyArray()) {
                val bytes = if (entry.isFile) entry.length() else 0L
                booksDirectoryBytes += bytes
                val (uuid, format) = BookContentService.decodeFilename(entry.name) ?: continue
                files[FileKey(uuid, format)] = bytes
            }
            var sizes = Sizes(files = files, booksDirectoryBytes = booksDirectoryBytes)

            if (scope == Scope.EVERYTHING) {
                sizes = sizes.copy(
                    extractedAudioBytes = directorySize(StorageRoot.directory("Audio")),
                    // Where the cover cache keeps its files: the caches root,
                    // not the durable one.
                    coverBytes = directorySize(File(StorageRoot.caches, "Covers")),
                    publisherFontBytes = subdirectorySize(StorageRoot.directory("Fonts")),
                    // Where the question indexes live.
                    askIndexBytes = directorySize(StorageRoot.directory("Ask")),
                    freeBytes = DiskSpace.available(StorageRoot.url) ?: 0,
                )
            }
            invoke(books, downloaded, sizes)
        }

        /** Recursive, because narration is extracted into a directory per book. */
        fun directorySize(directory: File): Long {
            if (!directory.isDirectory) return 0
            return directory.walkTopDown().filter { it != directory && it.isFile }.sumOf { it.length() }
        }

        /**
         * The subdirectories of a directory, and nothing at its root: for
         * `Fonts/`, where `Fonts/<book-uuid>/` came out of a download and a
         * face at the root was imported by the reader and is theirs.
         */
        fun subdirectorySize(directory: File): Long =
            (directory.listFiles() ?: emptyArray()).filter { it.isDirectory }.sumOf { directorySize(it) }
    }
}
