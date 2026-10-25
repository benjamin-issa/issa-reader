package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.download.BookContentService.Format
import com.benjaminissa.issareader.core.download.DownloadsInventory.FileKey
import com.benjaminissa.issareader.core.download.DownloadsInventory.Sizes
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.temporaryDirectory
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * What is on this device, without a screen. Ported from
 * `DownloadsInventoryTests.swift`: the grouping and the arithmetic are handed
 * their sizes rather than reading them, so every rule is checked against a
 * literal.
 */
class DownloadsInventoryTest {
    private fun book(uuid: String, title: String, author: String = ""): Book {
        val json = bookJson(uuid = uuid, title = title)
        json["authors"] = if (author.isEmpty()) emptyList<Any>() else listOf(mapOf("uuid" to author, "name" to author))
        json["ebook"] = mapOf("uuid" to "e", "filepath" to "e.epub", "identifiers" to emptyList<Any>())
        return decodeBook(json)
    }

    private fun key(uuid: String, format: Format) = FileKey(uuid, format)

    // Grouping

    /** A book with two editions on the device is two rows, and one book. */
    @Test
    fun twoEditionsAreTwoRowsAndOneBook() {
        val dracula = book("d", title = "Dracula", author = "Bram Stoker")
        val inventory = DownloadsInventory.make(
            books = listOf(dracula), downloaded = setOf("d"),
            sizes = Sizes(files = mapOf(key("d", Format.READALOUD) to 600L, key("d", Format.EBOOK) to 40L), booksDirectoryBytes = 640),
        )

        assertEquals(2, inventory.items.size)
        assertEquals("a reader counts books, not files", 1, inventory.bookCount)
        assertEquals(640L, inventory.itemBytes)
        assertEquals(setOf(Format.READALOUD, Format.EBOOK), inventory.items.map { it.format }.toSet())
    }

    /** A book with no file on this device has no row. */
    @Test
    fun aBookWithNoFileHasNoRow() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("d", title = "Dracula"), book("f", title = "Frankenstein")),
            downloaded = setOf("d"),
            sizes = Sizes(files = mapOf(key("d", Format.EBOOK) to 10L), booksDirectoryBytes = 10),
        )
        assertEquals(listOf("d"), inventory.items.map { it.book.uuid })
    }

    /** The downloaded set bounds the work, not the catalogue. */
    @Test
    fun theDownloadedSetBoundsTheScan() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("d", title = "Dracula")),
            downloaded = emptySet(),
            sizes = Sizes(files = mapOf(key("d", Format.EBOOK) to 10L), booksDirectoryBytes = 10),
        )
        assertTrue(inventory.items.isEmpty())
    }

    // Order

    /** The rows are largest first, because the question is what is taking the room. */
    @Test
    fun rowsAreLargestFirst() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("small", title = "A"), book("large", title = "B"), book("middle", title = "C")),
            downloaded = setOf("small", "large", "middle"),
            sizes = Sizes(
                files = mapOf(key("small", Format.EBOOK) to 10L, key("large", Format.EBOOK) to 900L, key("middle", Format.EBOOK) to 200L),
                booksDirectoryBytes = 1110,
            ),
        )
        assertEquals(listOf("large", "middle", "small"), inventory.items.map { it.book.uuid })
    }

    /** Rows of equal size keep a stable order: a list that reorders itself on every scan flickers. */
    @Test
    fun equalSizesAreOrderedStably() {
        val sizes = Sizes(files = mapOf(key("b", Format.EBOOK) to 100L, key("a", Format.EBOOK) to 100L), booksDirectoryBytes = 200)
        val first = DownloadsInventory.make(books = listOf(book("b", title = "Beta"), book("a", title = "Alpha")), downloaded = setOf("a", "b"), sizes = sizes)
        val second = DownloadsInventory.make(books = listOf(book("a", title = "Alpha"), book("b", title = "Beta")), downloaded = setOf("a", "b"), sizes = sizes)

        assertEquals(second.items.map { it.id }, first.items.map { it.id })
        assertEquals(listOf("Alpha", "Beta"), first.items.map { it.book.title })
    }

    // Per-format totals

    /** Each format's band is the sum of its own files. */
    @Test
    fun perFormatTotals() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("a", title = "A"), book("b", title = "B")),
            downloaded = setOf("a", "b"),
            sizes = Sizes(
                files = mapOf(key("a", Format.READALOUD) to 600L, key("b", Format.READALOUD) to 300L, key("a", Format.EBOOK) to 40L),
                booksDirectoryBytes = 940,
            ),
        )
        assertEquals(900L, inventory.byFormat[Format.READALOUD])
        assertEquals(40L, inventory.byFormat[Format.EBOOK])
        assertNull("a band with nothing in it is not drawn", inventory.byFormat[Format.AUDIOBOOK])
    }

    // The bytes with no row

    /** A download whose book has left the library is counted, not hidden. */
    @Test
    fun unaccountedBytesSurfaceADepartedBook() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")),
            downloaded = setOf("kept", "gone"),
            sizes = Sizes(files = mapOf(key("kept", Format.EBOOK) to 100L, key("gone", Format.READALOUD) to 500L), booksDirectoryBytes = 600),
        )
        assertEquals(100L, inventory.itemBytes)
        assertEquals(500L, inventory.unaccountedBytes)
        assertEquals("the headline still counts the whole directory", 600L, inventory.bookFileBytes)
        assertEquals(listOf(FileKey("gone", Format.READALOUD)), inventory.orphans)
    }

    /** A file the app did not name is counted but never offered for deletion. */
    @Test
    fun junkIsCountedButNotSwept() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept"),
            // 100 of book plus 20 of something else entirely.
            sizes = Sizes(files = mapOf(key("kept", Format.EBOOK) to 100L), booksDirectoryBytes = 120),
        )
        assertEquals(20L, inventory.unaccountedBytes)
        assertTrue("a sweep only touches files this app named", inventory.orphans.isEmpty())
    }

    /** What the sweep promises is what the sweep would delete. */
    @Test
    fun orphanBytesAreWhatTheSweepReclaims() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept", "gone"),
            // The two files, plus 40 bytes of something this app never wrote.
            sizes = Sizes(files = mapOf(key("kept", Format.EBOOK) to 100L, key("gone", Format.READALOUD) to 500L), booksDirectoryBytes = 640),
        )
        assertEquals("the bar still shows every byte with no row", 540L, inventory.unaccountedBytes)
        assertEquals("but the sweep can only reclaim the file it names", 500L, inventory.orphanBytes)
        assertTrue("the promise can never exceed the deletable set", inventory.orphanBytes <= inventory.unaccountedBytes)
    }

    /** A sweep with nothing to sweep promises nothing. */
    @Test
    fun noOrphansIsNoBytes() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept"),
            sizes = Sizes(files = mapOf(key("kept", Format.EBOOK) to 100L), booksDirectoryBytes = 140),
        )
        assertTrue(inventory.orphans.isEmpty())
        assertEquals(0L, inventory.orphanBytes)
        assertEquals("which is not the same as nothing to see", 40L, inventory.unaccountedBytes)
    }

    /** The headline counts the question indexes. */
    @Test
    fun askIndexesAreInTheHeadline() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept"),
            sizes = Sizes(
                files = mapOf(key("kept", Format.EBOOK) to 100L), booksDirectoryBytes = 100,
                extractedAudioBytes = 10, coverBytes = 5, publisherFontBytes = 2, askIndexBytes = 900,
            ),
        )
        assertEquals(900L, inventory.askIndexBytes)
        assertEquals(100L + 10 + 5 + 2 + 900, inventory.totalBytes)
    }

    /** The headline is the bands, with nothing over. */
    @Test
    fun theHeadlineIsTheSumOfTheBands() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept", "gone"),
            sizes = Sizes(
                files = mapOf(key("kept", Format.EBOOK) to 100L, key("gone", Format.READALOUD) to 500L),
                booksDirectoryBytes = 640, extractedAudioBytes = 10, coverBytes = 5, publisherFontBytes = 2, askIndexBytes = 900,
            ),
        )
        val bands = inventory.byFormat.values.sum() + inventory.extractedAudioBytes + inventory.coverBytes +
            inventory.publisherFontBytes + inventory.askIndexBytes + inventory.unaccountedBytes
        assertEquals(inventory.totalBytes, bands)
    }

    /** Everything adds up: rows plus the unaccounted is the directory. */
    @Test
    fun theBarAddsUpToTheHeadline() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("kept", title = "Kept")), downloaded = setOf("kept", "gone"),
            sizes = Sizes(
                files = mapOf(key("kept", Format.EBOOK) to 100L, key("gone", Format.EBOOK) to 400L),
                booksDirectoryBytes = 500, extractedAudioBytes = 30, coverBytes = 20, publisherFontBytes = 10,
            ),
        )
        val bands = inventory.byFormat.values.sum() + inventory.unaccountedBytes + inventory.extractedAudioBytes +
            inventory.coverBytes + inventory.publisherFontBytes
        assertEquals(inventory.totalBytes, bands)
    }

    /** A directory total behind the rows never yields a negative band. */
    @Test
    fun unaccountedNeverGoesNegative() {
        val inventory = DownloadsInventory.make(
            books = listOf(book("a", title = "A")), downloaded = setOf("a"),
            sizes = Sizes(files = mapOf(key("a", Format.EBOOK) to 500L), booksDirectoryBytes = 100),
        )
        assertEquals(0L, inventory.unaccountedBytes)
    }

    // The reconciliation diff

    /** A book whose last file went has departed. */
    @Test
    fun aBookThatLostItsLastFileHasDeparted() {
        assertEquals(setOf("b"), DownloadsInventory.departed(setOf("a", "b"), setOf("a")))
    }

    /** A book that still has one edition on the device has not departed. */
    @Test
    fun aBookWithAnotherEditionHasNotDeparted() {
        assertTrue(DownloadsInventory.departed(setOf("a"), setOf("a")).isEmpty())
    }

    /** A book that arrived is not a book that left. */
    @Test
    fun anArrivalIsNotADeparture() {
        assertTrue(DownloadsInventory.departed(setOf("a"), setOf("a", "b")).isEmpty())
    }

    // The reader-facing name

    /** An edition is named the way the app names it, never the way the server does. */
    @Test
    fun formatDisplayNames() {
        assertEquals("Read-along", Format.READALOUD.displayName)
        assertEquals("Ebook", Format.EBOOK.displayName)
        assertEquals("Audiobook", Format.AUDIOBOOK.displayName)
        for (format in Format.entries) {
            assertNotEquals("the server's spelling must not reach a reader", "readaloud", format.displayName.lowercase())
        }
    }

    // Naming a file both ways

    /** A download's filename decodes back to the book and the edition it came from. */
    @Test
    fun filenamesRoundTrip() {
        val directory = File("/tmp/books")
        for (format in Format.entries) {
            val file = BookContentService.localUrl(directory, "11111111-1111-4111-8111-111111111111", format)
            val decoded = BookContentService.decodeFilename(file.name)!!
            assertEquals("11111111-1111-4111-8111-111111111111", decoded.first)
            assertEquals(format, decoded.second)
        }
    }

    /** A file this app did not write is not claimed as a download. */
    @Test
    fun foreignFilenamesAreNotClaimed() {
        assertNull(BookContentService.decodeFilename("something.txt"))
        assertNull(BookContentService.decodeFilename("-ebook.epub"))
        assertNull(BookContentService.decodeFilename("a-unknown.epub"))
        assertNull(BookContentService.decodeFilename("not-a-uuid-ebook.epub"))
        // A uuid spelled in fullwidth digits is not the file this app wrote.
        val fullwidth = "１１１１１１１１-1111-4111-8111-111111111111"
        assertNull(BookContentService.decodeFilename("$fullwidth-ebook.epub"))
    }

    /**
     * A filename that decodes to a path traversal is not one of ours: a
     * decoded id is handed to the deleters, and `..` made both of their
     * directories the storage root.
     */
    @Test
    fun traversalFilenamesAreRefused() {
        for (name in listOf("..-ebook.epub", "..-readaloud.epub", "...-ebook.epub", "../..-ebook.epub", ".-audiobook.epub")) {
            assertNull("\"$name\" must never become a book id", BookContentService.decodeFilename(name))
            assertNull(BookContentService.bookUuid(fromFilename = name))
        }
    }

    /** A traversal filename on disk is neither downloaded nor an orphan. */
    @Test
    fun traversalFilesAreNotSwept() = runBlocking {
        val directory = temporaryDirectory("issa-traversal")
        directory.mkdirs()
        try {
            val real = "11111111-1111-4111-8111-111111111111"
            File(directory, "$real-ebook.epub").writeBytes(ByteArray(8))
            File(directory, "..-ebook.epub").writeBytes(ByteArray(8))

            assertEquals(setOf(real), BookContentService.downloadedBookUuids(directory))

            val inventory = DownloadsInventory.scan(
                books = emptyList(), downloaded = emptySet(), scope = DownloadsInventory.Scope.BOOKS_ONLY, booksDirectory = directory,
            )
            assertTrue("the sweep would have deleted the storage root", inventory.orphans.none { it.bookUuid == ".." })
            // Still counted in the directory total: the bytes are real.
            assertEquals(16L, inventory.bookFileBytes)
        } finally {
            directory.deleteRecursively()
        }
    }

    // The disk half

    /** The scan reads one directory and finds both the sizes and the total. */
    @Test
    fun scanReadsTheDirectoryOnce() = runBlocking {
        val directory = temporaryDirectory("issa-inventory")
        directory.mkdirs()
        try {
            val uuid = "11111111-1111-4111-8111-111111111111"
            BookContentService.localUrl(directory, uuid, Format.EBOOK).writeBytes(ByteArray(300))
            // Something the app did not write, so the total exceeds the rows.
            File(directory, "stray.tmp").writeBytes(ByteArray(25))

            val inventory = DownloadsInventory.scan(
                books = listOf(book(uuid, title = "Alice")), downloaded = setOf(uuid),
                scope = DownloadsInventory.Scope.BOOKS_ONLY, booksDirectory = directory,
            )

            assertEquals(1, inventory.items.size)
            assertEquals(300L, inventory.items.first().bytes)
            assertEquals(325L, inventory.bookFileBytes)
            assertEquals(25L, inventory.unaccountedBytes)
            // The cheap scope is the Reading tab's: no recursive walks at all.
            assertEquals(0L, inventory.extractedAudioBytes)
            assertEquals(0L, inventory.coverBytes)
            assertEquals(0L, inventory.publisherFontBytes)
        } finally {
            directory.deleteRecursively()
        }
    }

    /** Only the per-book subdirectories of a font folder are sized. */
    @Test
    fun onlyExtractedFacesAreSized() {
        val root = temporaryDirectory("issa-fonts")
        val extracted = File(root, "book-uuid")
        extracted.mkdirs()
        try {
            // The reader's own import, at the root.
            File(root, "Imported.otf").writeBytes(ByteArray(1000))
            // A publisher's face, under the book it came out of.
            File(extracted, "body.otf").writeBytes(ByteArray(40))

            assertEquals(40L, DownloadsInventory.subdirectorySize(root))
            assertEquals("the whole tree, for comparison", 1040L, DownloadsInventory.directorySize(root))
        } finally {
            root.deleteRecursively()
        }
    }
}
