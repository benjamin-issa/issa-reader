package com.benjaminissa.issareader.app.local

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookMetadata
import com.benjaminissa.issareader.core.model.LocalCopy
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.local
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.Instant
import java.util.Collections
import java.util.UUID
import kotlin.math.abs
import kotlin.math.floor
import kotlin.time.Duration.Companion.seconds

/**
 * What a file from the reader's own folders, or a device store in a bad way,
 * must not be able to do to the list: crash it, empty it, or leave it saying
 * something stale. Ported from `LocalBooksHardeningTests.swift`.
 */
class LocalBooksHardeningTest : AppSuite() {
    private val narrated = TestEpub.Chapter(
        "ch1", "One", "<p><span id=\"s0\">The night shift began.</span></p>", narrated = listOf("s0"),
    )

    private fun run(body: suspend (LocalFixtures, CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            body(local, scope)
        } finally {
            local.tearDown()
            scope.close()
        }
    }

    // R-01: a narration length no clock can show

    /**
     * `media:duration` is the book's word for its own length; 1e21 seconds is
     * finite, passes every check the parser makes, and trapped the row the
     * moment it was drawn. The one clip the overlay plays is what it lasts.
     */
    @Test
    fun absurdDurationIsNotKept() = run { local, _ ->
        val data = TestEpub.data(
            title = "The Long Night Shift", chapters = listOf(narrated),
            audio = ByteArray(512),
            metadata = "<meta property=\"media:duration\">1e21s</meta>",
        )

        local.importAndWait(local.pick(data, "night-shift.epub"))

        val book = checkNotNull(local.library.books.firstOrNull())
        assertTrue("the narration plays; only its stated length is absurd", book.hasReadalong)
        val seconds = checkNotNull(book.narrationDuration)
        assertTrue("kept $seconds s as the narration's length", abs(seconds - 1) < 0.01)
    }

    /** An absurd length with no sane clip behind it is clamped, never dropped. */
    @Test
    fun absurdTimelineIsClamped() {
        val ceiling = LocalBookImporter.LONGEST_NARRATION
        assertEquals(1.0, LocalBookImporter.narrationLength(1e21, 1.0))
        assertEquals(ceiling, LocalBookImporter.narrationLength(null, 1e21))
        assertEquals(ceiling, LocalBookImporter.narrationLength(Double.NaN, Double.POSITIVE_INFINITY))
        assertEquals(3600.0, LocalBookImporter.narrationLength(3600.0, 1e21))
        assertNull(LocalBookImporter.narrationLength(null, 0.0))
        assertNull(LocalBookImporter.narrationLength(0.0, 0.0))
    }

    /**
     * A row an earlier build stored with the absurd length still says what it
     * can: "Narrated" with no length rather than a trap. The row and Book info
     * themselves are composables, drawn by the screens' own tests.
     */
    @Test
    fun storedAbsurdLengthDraws() {
        val book = Book.local(
            uuid = UUID.randomUUID().toString().lowercase(),
            metadata = LocalBookMetadata(title = "The Long Night Shift"),
            narrationDuration = 1e21,
            copy = LocalCopy(fileName = "night-shift.epub", fingerprint = "f", byteCount = 4096, importedAt = Instant.now()),
        )
        assertTrue(book.hasReadalong)

        assertEquals("Narrated", LocalBooksCopy.narrated(1e21))
        assertEquals("Narrated", LocalBooksCopy.narrated(Double.POSITIVE_INFINITY))
        assertEquals("Narrated · 7 h 4 min", LocalBooksCopy.narrated(25_440.0))
        assertEquals("Narrated · 1 min", LocalBooksCopy.narrated(20.0))
        val facts = LocalBookFacts(book, size = 4096, isMissing = false, isPlaying = false)
        assertEquals("Narrated", facts.narration)
        assertTrue(facts.spoken.contains("Narrated"))
    }

    // R-02: a store that cannot be read is not an empty library

    /** A device store that will not open leaves every book's folder alone. */
    @Test
    fun unreadableStoreKeepsFolders() = run { local, _ ->
        local.importAndWait(local.pick("alice"))
        val book = checkNotNull(local.library.books.firstOrNull())
        val storeFile = checkNotNull(local.library.store).url

        // What a corrupt file, or a later build's migration that failed on a
        // full disk, leaves behind.
        for (suffix in listOf("", "-wal", "-shm", "-journal")) File(storeFile.path + suffix).delete()
        storeFile.writeText("not a database, whatever its name says")
        val relaunched = local.relaunched()
        assertNull("the store opened; this test needs one that does not", relaunched.store)

        relaunched.load()

        assertTrue("the only copy of the book was deleted as a crash leftover", relaunched.files(book.uuid).epub.exists())
        assertTrue("an account's exit would take the kept book's index and style", book.uuid in relaunched.uuids)
    }

    /** A row that will not decode keeps its folder, and the rest load. */
    @Test
    fun undecodableRowKeepsItsFolder() = run { local, _ ->
        local.importAndWait(local.pick("alice"))
        local.importAndWait(local.pick("readalong"))
        val bad = checkNotNull(local.library.books.firstOrNull { it.title.startsWith("Alice") })
        val good = checkNotNull(local.library.books.firstOrNull { !it.title.startsWith("Alice") })
        val storeFile = checkNotNull(local.library.store).url

        // A row shape a newer build wrote, as far as this one can tell.
        execute("UPDATE book SET json = x'7B7D' WHERE uuid = '${bad.uuid}'", storeFile)
        val relaunched = local.relaunched()
        relaunched.load()

        assertEquals(listOf(good.uuid), relaunched.books.map { it.uuid })
        assertTrue("the folder of a row this build could not read was deleted", relaunched.files(bad.uuid).epub.exists())
        assertTrue(relaunched.files(good.uuid).epub.exists())
        assertTrue(bad.uuid in relaunched.uuids)
    }

    /** One statement against a SQLite file, outside the store. */
    private suspend fun execute(sql: String, file: File) = withContext(Dispatchers.IO) {
        BundledSQLiteDriver().open(file.path).use { connection ->
            connection.execSQL(sql)
            connection.prepare("SELECT changes()").use { statement ->
                assertTrue(statement.step())
                assertEquals(1L, statement.getLong(0))
            }
        }
    }

    // R-28: a file put back says what is true of it now

    /** A file put back under a restored record carries its own notices. */
    @Test
    fun reattachCarriesNotices() = run { local, _ ->
        val opus = TestEpub.data(
            title = "The Opus Narration", chapters = listOf(narrated),
            audio = ByteArray(512), audioMediaType = "audio/opus",
        )
        val url = local.pick(opus, "opus.epub")
        local.importAndWait(url)
        val book = checkNotNull(local.library.books.firstOrNull())
        assertEquals(listOf(LocalNotice.NARRATION_UNPLAYABLE), book.localCopy?.notices)
        // Read, and dismissed: the restored record carries none.
        local.library.dismissNotice(LocalNotice.NARRATION_UNPLAYABLE, book.uuid)
        val cleared = waitUntil(2.seconds) {
            local.library.store?.book(book.uuid)?.localCopy?.notices?.isEmpty() == true
        }
        assertTrue(cleared)
        assertTrue(local.library.files(book.uuid).folder.deleteRecursively())
        val restored = local.relaunched()
        restored.load()
        assertEquals(setOf(book.uuid), restored.missingFiles)

        restored.importBooks(listOf(url), reattaching = book.uuid)
        restored.importsSettled()

        assertEquals(
            "the book stopped narrating with nothing on its row to say why",
            listOf(LocalNotice.NARRATION_UNPLAYABLE), restored.books.firstOrNull()?.localCopy?.notices,
        )
    }

    // R-30: Delete with no row focused removes nothing

    /** Delete removes only the row the keyboard is on. */
    @Test
    fun deleteNeedsAFocusedRow() {
        val books = listOf(SharedFixtures.book("Dracula", uuid = "11111111-1111-4111-8111-111111111111"))
        assertNull(LocalBooksKeyboard.removalTarget(null))
        assertEquals("Ctrl+I may still guess", books[0].uuid, LocalBooksKeyboard.infoTarget(null, books))
        assertEquals(books[0].uuid, LocalBooksKeyboard.removalTarget(books[0].uuid))
    }

    // R-19: a description written as markup

    /** A description Calibre wrote as markup reads as text in Book info. */
    @Test
    fun descriptionMarkupIsRendered() {
        val about = checkNotNull(LocalBookInfo.aboutText("<div><p>A tale of salt &amp; ash.</p><p>Second <i>part</i>.</p></div>"))
        assertTrue("tags on screen: $about", !about.contains("<"))
        assertTrue(!about.contains("&amp;"))
        assertTrue(about.contains("A tale of salt & ash."))
        assertTrue(about.contains("Second part."))
        assertNull(LocalBookInfo.aboutText("<p> </p>"))
        assertNull(LocalBookInfo.aboutText(null))
    }

    // A book from another volume

    /**
     * What a USB drive or a network share gets — and on Android every
     * provider's file — is a chunked copy. It read past the end of the file
     * as a failure, so every such book was refused as "Couldn't copy this book".
     */
    @Test
    fun chunkedCopyReachesTheEnd() = run { local, _ ->
        val url = local.pick("readalong")

        val row = local.importAndWait(url)

        assertNotEquals("the chunked copy failed at the end of the file", LocalImport.Stage.Failed(LocalImportError.CopyFailed), row?.stage)
        val book = checkNotNull(local.library.books.firstOrNull())
        val picked = File(checkNotNull(url.path))
        assertTrue(local.library.files(book.uuid).epub.readBytes().contentEquals(picked.readBytes()))
        assertEquals(LocalBookImporter.sha256(picked), book.localCopy?.fingerprint)
    }

    // R-63: the copy says how far it has got, not every megabyte

    /** The chunked copy reports whole percents only, and hashes as it copies. */
    @Test
    fun copyReportsArePercents() = run { local, _ ->
        val importer = local.library.importer
        importer.chunkSize = 16
        val url = local.pick("readalong")
        val reports = Collections.synchronizedList(ArrayList<LocalImport.Stage>())

        val prepared = withContext(Dispatchers.IO) { importer.run(url, UUID.randomUUID().toString()) { reports.add(it) } }
        try {
            val fractions = synchronized(reports) { reports.mapNotNull { (it as? LocalImport.Stage.Copying)?.fraction } }
            assertTrue(fractions.isNotEmpty())
            assertTrue("${fractions.size} progress reports for one small file", fractions.size <= 101)
            val percents = fractions.map { floor(it * 100).toInt() }
            assertTrue(
                "a report that did not move the whole percent",
                percents == percents.sorted() && percents.toSet().size == percents.size,
            )
            assertEquals(LocalBookImporter.sha256(File(checkNotNull(url.path))), prepared.fingerprint)
        } finally {
            prepared.discard()
        }
    }
}
