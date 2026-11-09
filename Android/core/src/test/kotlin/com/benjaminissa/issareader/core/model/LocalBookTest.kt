package com.benjaminissa.issareader.core.model

import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.fixture
import com.benjaminissa.issareader.core.fixtureBooks
import com.benjaminissa.issareader.core.instantOfEpochSeconds
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.LibraryService
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneOffset
import java.time.ZonedDateTime
import java.util.UUID

/**
 * Books from the reader's files: how one is made, how it is kept, and how a
 * server is kept from passing one of its own off as one. Ported from
 * `LocalBookTests.swift`.
 */
class LocalBookTest {
    companion object {
        fun directory(): File = File(System.getProperty("java.io.tmpdir"), "issa-local-${UUID.randomUUID()}")

        fun copy(notices: List<LocalNotice> = emptyList()): LocalCopy = LocalCopy(
            fileName = "peter-and-wendy.epub",
            fingerprint = "ab".repeat(32),
            byteCount = 1_048_576,
            importedAt = instantOfEpochSeconds(1_790_000_000.0),
            hasCover = true,
            packageIdentifier = "urn:uuid:invented",
            epubVersion = "3.0",
            notices = notices,
        )

        val metadata = LocalBookMetadata(
            title = "The Keeper of the Lamp",
            subtitle = "A Fixture",
            description = "Invented.",
            language = "en",
            date = "2008-06-27",
            authors = listOf(LocalContributor(name = "Ada Fixture", fileAs = "Fixture, Ada", role = "aut")),
            narrators = listOf(LocalContributor(name = "Noel Reader", role = "nrt")),
            creators = listOf(LocalContributor(name = "Iris Illustrator", role = "ill")),
            series = LocalSeries(name = "Lamps and Ledgers", position = 2.0),
            identifier = "urn:uuid:invented",
        )

        fun uuid(): String = UUID.randomUUID().toString().lowercase()
    }

    // The factory

    /** A narrated book is a read-along the app can narrate. */
    @Test
    fun alignedBook() {
        val uuid = uuid()
        val book = Book.local(uuid = uuid, metadata = metadata, narrationDuration = 25_440.0, copy = copy())
        assertEquals(uuid, book.uuid)
        assertTrue(book.isLocal)
        assertTrue(book.hasReadalong)
        assertEquals(true, book.readaloud?.isAligned)
        assertEquals(setOf(BookFormat.READALOUD), book.servableFormats)
        assertEquals(25_440.0, book.narrationDuration)
        assertTrue(book.isReadable)
        assertNull(book.ebook)
        assertEquals("The Keeper of the Lamp", book.title)
        assertEquals("A Fixture", book.displaySubtitle)
        assertEquals("Ada Fixture", book.byline)
        assertEquals(listOf("Noel Reader"), book.narrators.map { it.name })
        assertEquals(listOf("ill"), book.creators.map { it.role })
        assertEquals("Lamps and Ledgers", book.primarySeries?.name)
        assertEquals(2.0, book.primarySeries?.position)
        assertEquals(instantOfEpochSeconds(1_790_000_000.0), book.createdAt?.value)
        assertNotNull(book.publicationDate)
        // Nothing a server would know about.
        assertNull(book.status)
        assertNull(book.position)
        assertTrue(book.tags.isEmpty())
    }

    /** A book without playable narration is an ebook only. */
    @Test
    fun plainBook() {
        for (duration in listOf(null, 0.0)) {
            val book = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = duration, copy = copy())
            assertFalse(book.hasReadalong)
            assertEquals(setOf(BookFormat.EBOOK), book.servableFormats)
            assertNull(book.narrationDuration)
            assertTrue(book.isReadable)
            assertEquals("book.epub", book.ebook?.filepath)
        }
    }

    /**
     * A year, a month or a day is a publication date: books date themselves
     * that way far more often than by the second.
     */
    @Test
    fun publicationDates() {
        fun utc(y: Int, m: Int, d: Int) = ZonedDateTime.of(y, m, d, 0, 0, 0, 0, ZoneOffset.UTC).toInstant()
        assertEquals(utc(1911, 1, 1), LocalBookMetadata.parseDate("1911"))
        assertEquals(utc(1911, 5, 1), LocalBookMetadata.parseDate("1911-05"))
        assertEquals(utc(2008, 6, 27), LocalBookMetadata.parseDate(" 2008-06-27 "))
        assertNotNull(LocalBookMetadata.parseDate("2026-08-01T07:31:52Z"))
        for (nonsense in listOf("", "c. 1900", "1911-13-01", "19-05", "MCMXI")) {
            assertNull(nonsense, LocalBookMetadata.parseDate(nonsense))
        }
    }

    /** Every book gets the uuid it is given, and a fresh one is fresh. */
    @Test
    fun freshUuids() {
        val a = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = null, copy = copy())
        val b = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = null, copy = copy())
        assertNotEquals(a.uuid, b.uuid)
        assertTrue(a.uuid.isBareUuid)
        // Creator ids are the book's own, so two books never share one.
        assertTrue(a.authors.map { it.uuid }.toSet().intersect(b.authors.map { it.uuid }.toSet()).isEmpty())
    }

    /** Notices a later build adds survive this build's round trip. */
    @Test
    fun unknownNotices() {
        var copy = copy(notices = listOf(LocalNotice.FIXED_LAYOUT))
        copy = copy.copy(noticeValues = copy.noticeValues + "aNoticeFromTheFuture")
        val data = IssaJson.encodeToString(LocalCopy.serializer(), copy)
        var decoded = IssaJson.decodeFromString(LocalCopy.serializer(), data)
        assertEquals(listOf(LocalNotice.FIXED_LAYOUT), decoded.notices)
        decoded = decoded.withNotices(emptyList())
        assertEquals(listOf("aNoticeFromTheFuture"), decoded.noticeValues)
    }

    // The device store

    /** A local book survives a round trip through the device store. */
    @Test
    fun storeRoundTrip() = runBlocking {
        val directory = directory()
        try {
            val book = Book.local(
                uuid = uuid(), metadata = metadata, narrationDuration = 120.0,
                copy = copy(notices = listOf(LocalNotice.NARRATION_UNPLAYABLE)),
            )
            LibraryStore(serverKey = LibraryStore.deviceBooksKey, directory = directory).use { it.upsert(book) }

            LibraryStore(serverKey = LibraryStore.deviceBooksKey, directory = directory).use { reopened ->
                val restored = reopened.book(book.uuid)!!
                assertEquals(book, restored)
                assertEquals(listOf(LocalNotice.NARRATION_UNPLAYABLE), restored.localCopy?.notices)
                assertTrue(restored.isLocal)
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /** The device store is its own file, apart from any server's. */
    @Test
    fun deviceStoreIsSeparate() = runBlocking {
        val directory = directory()
        try {
            LibraryStore(serverKey = LibraryStore.deviceBooksKey, directory = directory).use { device ->
                LibraryStore(serverKey = "https://library.example", directory = directory).use { server ->
                    assertNotEquals(device.url, server.url)

                    val book = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = null, copy = copy())
                    device.upsert(book)
                    assertTrue(server.allBooks().isEmpty())
                    // A server's catalogue replacing itself does not reach the device's.
                    server.replaceCatalogue(emptyList())
                    assertEquals(1, device.allBooks().size)
                }
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    /** Removing a book removes its row and its audio anchor, and nothing else. */
    @Test
    fun deletions() = runBlocking {
        val directory = directory()
        try {
            LibraryStore(serverKey = LibraryStore.deviceBooksKey, directory = directory).use { store ->
                val gone = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = 60.0, copy = copy())
                val kept = Book.local(uuid = uuid(), metadata = metadata, narrationDuration = 60.0, copy = copy())
                for (book in listOf(gone, kept)) {
                    store.upsert(book)
                    store.setAudioAnchor(AudioAnchor(audioHref = "OEBPS/Audio/1.mp3", offset = 3.0, writtenAt = 1.0), bookUuid = book.uuid)
                }

                store.deleteBook(gone.uuid)
                store.deleteAudioAnchor(bookUuid = gone.uuid)

                assertNull(store.book(gone.uuid))
                assertNull(store.audioAnchor(bookUuid = gone.uuid))
                assertNotNull(store.book(kept.uuid))
                assertNotNull(store.audioAnchor(bookUuid = kept.uuid))
            }
        } finally {
            directory.deleteRecursively()
        }
    }

    // Files

    /** A book's files are all inside its own folder. */
    @Test
    fun files() {
        val root = directory()
        val uuid = uuid()
        val files = LocalBookFiles(bookUuid = uuid, root = root)
        assertEquals(File(root, uuid), files.folder)
        for (file in listOf(files.epub, files.cover, files.narration, files.fonts)) {
            assertTrue(file.path.startsWith(files.folder.path + "/"))
        }
        assertEquals("book.epub", files.epub.name)
        assertEquals("cover.jpg", files.cover.name)
        assertTrue(LocalBookFiles.incoming(root).path.startsWith(root.path + "/"))
    }

    /**
     * An id that is not a uuid cannot climb out of the Local folder: the
     * folder is deleted whole when its book goes.
     */
    @Test
    fun unsafeId() {
        val root = directory()
        val files = LocalBookFiles(bookUuid = "..", root = root)
        assertEquals(root.normalize(), files.folder.normalize().parentFile)
        assertTrue(files.folder.name.startsWith("unsafe-"))
    }

    // A server cannot make a book local

    /** Server catalogues decode with no local copy. */
    @Test
    fun serverBooksAreNotLocal() {
        for (name in listOf("books", "v3/books")) {
            val books = fixtureBooks(name)
            assertFalse(books.isEmpty())
            assertTrue(books.all { !it.isLocal })
        }
    }

    /**
     * A server that sends a local copy has it stripped. The field decodes —
     * the device store depends on it — so the strip is at the catalogue's
     * boundary, and both doors in through it are checked.
     */
    @Test
    fun serverSentLocalCopyIsStripped() {
        val json = IssaJson.parseToJsonElement(fixture("books")).jsonArray
        val copy = IssaJson.encodeToJsonElement(LocalCopy.serializer(), copy())
        val first = JsonObject(json[0].jsonObject + ("issaLocal" to copy))
        val edited = JsonArray(listOf(first) + json.drop(1))
        val books = IssaJson.decodeFromJsonElement(ListSerializer(Book.serializer()), edited)
        assertTrue("the field has to decode for the strip to mean anything", books[0].isLocal)

        assertTrue(LibraryService.refusingUnsafeIdentifiers(books).all { !it.isLocal })
        assertFalse(LibraryService.refusingUnsafeIdentifier(books[0]).isLocal)
    }
}

