package com.benjaminissa.issareader.core.download

import com.benjaminissa.issareader.core.assertThrowing
import com.benjaminissa.issareader.core.bookJson
import com.benjaminissa.issareader.core.decodeBook
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.networking.ApiClient
import com.benjaminissa.issareader.core.networking.TokenProviding
import com.benjaminissa.issareader.core.temporaryDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.io.IOException
import java.net.URI
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions

/**
 * What a book can actually serve: what the app is willing to promise about a
 * book, and which file it opens. Ported from `BookFormatTests.swift`.
 *
 * Both questions used to be answered without consulting `missing`, which is
 * how an audiobook-only book came to offer "Read" and how a book the server
 * had lost still started a download that 404'd.
 */
class BookFormatTest {
    private class Edition(val filepath: String? = null, val aligned: Boolean = false, val missing: Boolean? = null)

    private fun book(ebook: Edition? = null, readaloud: Edition? = null, audiobook: Edition? = null): Book {
        val json = bookJson(uuid = "u", title = "A Book")
        if (ebook != null) {
            val edition = mutableMapOf<String, Any?>("uuid" to "e", "identifiers" to emptyList<Any>())
            ebook.missing?.let { edition["missing"] = it }
            json["ebook"] = edition
        }
        if (readaloud != null) {
            val edition = mutableMapOf<String, Any?>(
                "uuid" to "r", "identifiers" to emptyList<Any>(),
                "status" to if (readaloud.aligned) "ALIGNED" else "PROCESSING",
            )
            readaloud.filepath?.let { edition["filepath"] = it }
            readaloud.missing?.let { edition["missing"] = it }
            json["readaloud"] = edition
        }
        if (audiobook != null) {
            val edition = mutableMapOf<String, Any?>("uuid" to "a", "identifiers" to emptyList<Any>())
            audiobook.filepath?.let { edition["filepath"] = it }
            audiobook.missing?.let { edition["missing"] = it }
            json["audiobook"] = edition
        }
        return decodeBook(json)
    }

    // Which file the reader opens

    /** An audiobook-only book has nothing to read: the reader offered "Read" and failed on the next screen. */
    @Test
    fun audiobookOnlyHasNoReadingFormat() {
        assertNull(BookContentService.preferredReadingFormat(book(audiobook = Edition(filepath = "a.m4b"))))
    }

    /** Only a book with text is readable. */
    @Test
    fun isReadableTracksServableText() {
        assertFalse(book(audiobook = Edition(filepath = "a.m4b")).isReadable)
        assertTrue(book(ebook = Edition()).isReadable)
        assertTrue(book(readaloud = Edition(filepath = "r.epub", aligned = false)).isReadable)
        assertFalse(book(ebook = Edition(missing = true), audiobook = Edition(filepath = "a.m4b")).isReadable)
    }

    /** An ebook the server has lost is not offered. */
    @Test
    fun missingEbookIsNotAReadingFormat() {
        assertNull(BookContentService.preferredReadingFormat(book(ebook = Edition(missing = true))))
    }

    /** A missing readaloud falls back to the healthy ebook. */
    @Test
    fun missingReadaloudFallsBackToEbook() {
        val subject = book(ebook = Edition(), readaloud = Edition(filepath = "r.epub", aligned = true, missing = true))
        assertEquals(BookContentService.Format.EBOOK, BookContentService.preferredReadingFormat(subject))
    }

    /** An aligned readaloud still wins over a plain ebook. */
    @Test
    fun alignedReadaloudIsPreferred() {
        val subject = book(ebook = Edition(), readaloud = Edition(filepath = "r.epub", aligned = true))
        assertEquals(BookContentService.Format.READALOUD, BookContentService.preferredReadingFormat(subject))
    }

    /** An unaligned readaloud is still readable when it is all there is. */
    @Test
    fun unalignedReadaloudIsTheLastResort() {
        val subject = book(readaloud = Edition(filepath = "r.epub", aligned = false))
        assertEquals(BookContentService.Format.READALOUD, BookContentService.preferredReadingFormat(subject))
    }

    /** An absent missing flag means the edition is there. */
    @Test
    fun absentMissingMeansPresent() {
        assertEquals(BookContentService.Format.EBOOK, BookContentService.preferredReadingFormat(book(ebook = Edition())))
    }

    // What the library grid promises

    /**
     * A readaloud with no file is not servable, however aligned it says it is:
     * the server creates the row when alignment is *requested*.
     */
    @Test
    fun readaloudWithoutFileIsNotServable() {
        val subject = book(readaloud = Edition(filepath = null, aligned = true))
        assertTrue(BookFormat.READALOUD in subject.availableFormats) // the row exists
        assertFalse(BookFormat.READALOUD in subject.servableFormats) // the file does not
    }

    /** An audiobook marked missing is not servable. */
    @Test
    fun missingAudiobookIsNotServable() {
        assertFalse(BookFormat.AUDIOBOOK in book(audiobook = Edition(filepath = "a.m4b", missing = true)).servableFormats)
    }

    /** A plain ebook is servable. */
    @Test
    fun plainEbookIsServable() {
        assertEquals(setOf(BookFormat.EBOOK), book(ebook = Edition()).servableFormats)
    }
}

private class NoTokens : TokenProviding {
    override suspend fun currentToken(): String? = null
    override suspend fun invalidate() {}
}

/**
 * Naming downloaded files: reading the download directory instead of asking
 * about each book in turn. Ported from `DownloadFilenameTests` in
 * `BookFormatTests.swift`.
 */
class DownloadFilenameTest {
    companion object {
        /** A canonical uuid — the only shape the catalogue admits. */
        const val UUID = "0198ab12-cd34-4e56-8f90-123456789abc"
    }

    private fun service(): BookContentService {
        val directory = File("/tmp/does-not-matter")
        return BookContentService(ApiClient(baseUrl = URI("file:///tmp/does-not-matter"), tokens = NoTokens()), cacheDirectory = directory)
    }

    private fun book(uuid: String): Book = decodeBook(bookJson(uuid = uuid, title = "T"))

    /** A filename round-trips to its book for every format. */
    @Test
    fun roundTripsEveryFormat() {
        val subject = book(UUID)
        for (format in BookContentService.Format.entries) {
            val name = service().localUrl(subject, format).name
            assertEquals(UUID, BookContentService.bookUuid(fromFilename = name))
        }
    }

    /**
     * A uuid that could escape the directory is contained, not round-tripped:
     * one redundant download in a case the catalogue already refuses, against
     * letting the server choose the path.
     */
    @Test
    fun hostileIdentifiersAreContained() {
        val hostile = book("../../Library/Preferences/x")
        val file = service().localUrl(hostile, BookContentService.Format.EBOOK)
        assertTrue(file.name.startsWith("unsafe-"))
        assertFalse("the written path must stay inside Books", file.path.contains(".."))
        assertNotEquals("../../Library/Preferences/x", BookContentService.bookUuid(fromFilename = file.name))
    }

    /** Anything that is not one of ours is ignored. */
    @Test
    fun rejectsStrays() {
        assertNull(BookContentService.bookUuid(fromFilename = "garbage"))
        assertNull(BookContentService.bookUuid(fromFilename = "uuid.epub"))
        assertNull(BookContentService.bookUuid(fromFilename = "uuid-nonsense.epub"))
        assertNull(BookContentService.bookUuid(fromFilename = "-ebook.epub"))
        // A stem that is not a bare uuid is not one of ours either: a decoded
        // id is handed straight to the deleters, and `..` names the root.
        assertNull(BookContentService.bookUuid(fromFilename = "one-ebook.epub"))
        assertNull(BookContentService.bookUuid(fromFilename = "..-ebook.epub"))
    }

    /** One book with several formats on disk counts once. */
    @Test
    fun oneEntryPerBookRegardlessOfFormats() {
        val directory = temporaryDirectory("issa-downloads")
        directory.mkdirs()
        try {
            val one = "11111111-1111-4111-8111-111111111111"
            val two = "22222222-2222-4222-8222-222222222222"
            for (name in listOf("$one-ebook.epub", "$one-readaloud.epub", "$two-audiobook.epub", "notes.txt")) {
                File(directory, name).writeBytes(ByteArray(0))
            }
            assertEquals(setOf(one, two), BookContentService.downloadedBookUuids(directory))
        } finally {
            directory.deleteRecursively()
        }
    }

    /**
     * A directory that cannot be read is an error, not an empty library: the
     * sweep downstream reads "no books on disk" as "every book departed" and
     * deletes what none of them can get back.
     *
     * A privileged process (the container this suite runs in, as root) reads
     * through any permission, so there the unreadable directory is one that
     * exists but cannot be listed at all — the same distinction, from a
     * different cause.
     */
    @Test
    fun unreadableDirectoryThrows() {
        val directory = temporaryDirectory("issa-unreadable")
        directory.mkdirs()
        try {
            File(directory, "$UUID-ebook.epub").writeBytes(ByteArray(0))
            // Unreadable, but emphatically not empty.
            Files.setPosixFilePermissions(directory.toPath(), PosixFilePermissions.fromString("---------"))
            if (Files.isReadable(directory.toPath())) {
                Files.setPosixFilePermissions(directory.toPath(), PosixFilePermissions.fromString("rwxr-xr-x"))
                val notADirectory = File(directory, "Books")
                notADirectory.writeText("a file where the directory should be")
                assertThrowing<IOException> { BookContentService.downloadedBookUuids(notADirectory) }
            } else {
                assertThrowing<IOException> { BookContentService.downloadedBookUuids(directory) }
            }
        } finally {
            Files.setPosixFilePermissions(directory.toPath(), PosixFilePermissions.fromString("rwxr-xr-x"))
            directory.deleteRecursively()
        }
    }

    /**
     * A directory that is not there is genuinely empty: a fresh install, and
     * "sign out and delete my downloads", both leave no directory at all.
     */
    @Test
    fun absentDirectoryIsEmpty() {
        assertTrue(BookContentService.downloadedBookUuids(temporaryDirectory("issa-absent")).isEmpty())
    }
}
