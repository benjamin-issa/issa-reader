package com.benjaminissa.issareader.app.local

import android.content.res.XmlResourceParser
import android.graphics.BitmapFactory
import android.net.Uri
import com.benjaminissa.issareader.R
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.BookFormat
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.LocalNotice
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.isBareUuid
import com.benjaminissa.issareader.core.model.isLocal
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.PositionOrigin
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.robolectric.RuntimeEnvironment
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs
import kotlin.time.Duration.Companion.seconds

/**
 * Adding a book from the reader's files: the copy, the checks, the row, and
 * every refusal and notice the copy deck has words for. Ported from
 * `LocalImportTests.swift`; "iPhone" in its copy is "phone" here.
 */
class LocalImportTest : AppSuite() {
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

    private fun fileOf(uri: Uri): File = File(checkNotNull(uri.path))

    /** What the backup rules include: naming what is included excludes everything else. */
    private fun backedUpPaths(): List<String> {
        val parser: XmlResourceParser = RuntimeEnvironment.getApplication().resources.getXml(R.xml.data_extraction_rules)
        val paths = ArrayList<String>()
        while (parser.next() != XmlResourceParser.END_DOCUMENT) {
            if (parser.eventType == XmlResourceParser.START_TAG && parser.name == "include") {
                paths.add("${parser.getAttributeValue(null, "domain")}:${parser.getAttributeValue(null, "path")}")
            }
        }
        return paths
    }

    // What a good file becomes

    /** The read-along fixture is added as a narrated book, with no cover to cut. */
    @Test
    fun readalongIsAligned() = run { local, _ ->
        val url = local.pick("readalong")

        local.importAndWait(url)

        val book = checkNotNull(local.library.books.firstOrNull())
        assertEquals(1, local.library.books.size)
        assertTrue(book.isLocal)
        assertTrue(book.uuid.isBareUuid)
        assertTrue("every file of its narration is MP3, which plays here", book.hasReadalong)
        assertEquals("The Patient Record of the Days", book.title)
        assertEquals("A. Fixture", book.byline)
        assertTrue(book.narrationDuration?.let { abs(it - 32.75) < 0.01 } == true)
        val copy = checkNotNull(book.localCopy)
        assertEquals("readalong.epub", copy.fileName)
        assertEquals(LocalBookImporter.sha256(fileOf(url)), copy.fingerprint)
        assertEquals(fileOf(url).length(), copy.byteCount)
        assertFalse(copy.hasCover)
        assertTrue(copy.notices.isEmpty())
        assertEquals("urn:uuid:issa-readalong-fixture", copy.packageIdentifier)

        val files = local.library.files(book.uuid)
        assertTrue(files.epub.exists())
        assertFalse(files.cover.exists())
        assertTrue("the copy is the file", files.epub.readBytes().contentEquals(fileOf(url).readBytes()))
        assertTrue("the original is never touched", fileOf(url).exists())
        assertTrue("nothing left in flight", local.incoming().isEmpty())
        // Out of backups, the whole tree: the original is still in the reader's files.
        // Android has no per-file flag; the rules name what is backed up.
        assertTrue("Local/ is backed up: ${backedUpPaths()}", backedUpPaths().none { it.startsWith("file:Local") })

        // The row was written, and a relaunch finds the book.
        val relaunched = local.relaunched()
        relaunched.load()
        assertEquals(listOf(book.uuid), relaunched.books.map { it.uuid })
        assertTrue(relaunched.missingFiles.isEmpty())
    }

    /** A book with a cover gets one cut at import. */
    @Test
    fun coverIsCut() = run { local, _ ->
        local.importAndWait(local.pick("alice"))

        val book = checkNotNull(local.library.books.firstOrNull())
        assertEquals(true, book.localCopy?.hasCover)
        assertFalse(book.hasReadalong)
        assertEquals(setOf(BookFormat.EBOOK), book.servableFormats)
        val cover = local.library.files(book.uuid).cover
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(cover.path, bounds)
        assertTrue("no image at ${cover.path}", bounds.outWidth > 0 && bounds.outHeight > 0)
        assertTrue(maxOf(bounds.outWidth, bounds.outHeight) <= 1200)
        assertEquals("image/jpeg", bounds.outMimeType)
    }

    // Already here, and back from a backup

    /** The same file a second time is already here: nothing is added. */
    @Test
    fun duplicate() = run { local, _ ->
        local.importAndWait(local.pick("alice"))
        val first = checkNotNull(local.library.books.firstOrNull())

        // A second copy under another name: matched by identifier and hash, not by name.
        local.importAndWait(local.pick("alice", "alice (1).epub"))

        assertEquals(listOf(first.uuid), local.library.books.map { it.uuid })
        assertEquals(first.uuid, local.library.duplicate?.uuid)
        assertEquals("${first.title} is already on this phone.", LocalBooksCopy.alreadyHere(first.title))
        val folders = local.root.list()?.filter { !it.startsWith(".") }.orEmpty()
        assertEquals("a second folder was made for a book already here", 1, folders.size)
        assertTrue("the duplicate's copy was left in flight", local.incoming().isEmpty())
        assertTrue("a duplicate leaves no problem row", local.library.imports.isEmpty())
    }

    /** A book whose file went missing is put back by choosing it again, with the reader's place. */
    @Test
    fun reattach() = run { local, _ ->
        val url = local.pick("readalong")
        local.importAndWait(url)
        val book = checkNotNull(local.library.books.firstOrNull())
        val locator = ReadiumLocator(
            href = "OEBPS/ch02.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.5, totalProgression = 0.75),
        )
        assertTrue(local.library.writePosition(locator, 42.0, PositionOrigin.CHOSEN, book.uuid))

        // The backup brought back the store and not the copy.
        assertTrue(local.library.files(book.uuid).folder.deleteRecursively())
        val restored = local.relaunched()
        restored.load()
        assertEquals(setOf(book.uuid), restored.missingFiles)

        restored.importBooks(listOf(url))
        restored.importsSettled()

        assertTrue(restored.missingFiles.isEmpty())
        assertEquals("a reattach is the same book, not a new one", listOf(book.uuid), restored.books.map { it.uuid })
        assertEquals(0.75, restored.books.firstOrNull()?.position?.locator?.locations?.totalProgression)
        assertTrue(restored.files(book.uuid).epub.exists())
        assertNull(restored.duplicate)
    }

    /** Add Again with a different book is refused, and says which file it wants. */
    @Test
    fun reattachTheWrongBook() = run { local, _ ->
        local.importAndWait(local.pick("readalong", "emma.epub"))
        val book = checkNotNull(local.library.books.firstOrNull())
        assertTrue(local.library.files(book.uuid).epub.delete())
        val restored = local.relaunched()
        restored.load()

        restored.importBooks(listOf(local.pick("alice")), reattaching = book.uuid)
        restored.importsSettled()

        val row = checkNotNull(restored.imports.firstOrNull())
        assertEquals(LocalImport.Stage.Failed(LocalImportError.NotTheSameBook("emma.epub")), row.stage)
        assertEquals(LocalImportError.Action.CHOOSE_AGAIN, LocalImportError.NotTheSameBook("emma.epub").action)
        assertEquals(1, restored.books.size)
        assertEquals(setOf(book.uuid), restored.missingFiles)
    }

    // Refusals

    /** A text file called .epub is not an EPUB, and a PDF says it is one. */
    @Test
    fun notAnEpub() = run { local, _ ->
        val renamed = local.pick("Notes to self, not a book.".toByteArray(), "notes.epub")
        val pdf = local.pick("%PDF-1.7".toByteArray(), "Field Notes.pdf")

        local.library.importBooks(listOf(renamed, pdf))
        local.library.importsSettled()

        assertEquals(
            listOf(LocalImport.Stage.Failed(LocalImportError.NotAnEpub(null)), LocalImport.Stage.Failed(LocalImportError.NotAnEpub("a PDF"))),
            local.library.imports.map { it.stage },
        )
        assertEquals("This is a PDF. Issa Reader can open EPUB books only.", LocalImportError.NotAnEpub("a PDF").reason)
        assertTrue(local.library.books.isEmpty())
        assertTrue(local.incoming().isEmpty())
    }

    /** A folder is refused as a folder. */
    @Test
    fun folder() = run { local, _ ->
        val folder = File(local.picked, "Dracula.epub").apply { mkdirs() }

        val row = local.importAndWait(Uri.fromFile(folder))
        assertEquals(LocalImport.Stage.Failed(LocalImportError.Folder), row?.stage)
        assertEquals("This is a folder", LocalImportError.Folder.title)
    }

    /** A copy-protected book is refused, with the words that explain DRM. */
    @Test
    fun drm() = run { local, _ ->
        val locked = TestEpub.data(
            title = "The Glass Hours",
            chapters = listOf(TestEpub.Chapter("ch1", "One", "<p>Words behind a lock.</p>")),
            extras = listOf("META-INF/rights.xml" to "<rights/>".toByteArray()),
        )

        val row = local.importAndWait(local.pick(locked, "The Glass Hours.epub"))

        assertEquals(LocalImport.Stage.Failed(LocalImportError.DrmProtected), row?.stage)
        assertTrue(LocalImportError.DrmProtected.reason.startsWith("It has DRM, a lock some shops add"))
        assertNull(LocalImportError.DrmProtected.action)
        assertTrue(local.library.books.isEmpty())
        assertTrue("the locked copy was left behind", local.incoming().isEmpty())
    }

    /** A book with no readable chapter is damaged. */
    @Test
    fun damaged() = run { local, _ ->
        // A spine whose only item names a file the archive does not hold:
        // renaming the member in both of its headers leaves the manifest
        // pointing at nothing.
        val bytes = TestEpub.data(chapters = listOf(TestEpub.Chapter("ch1", "One", "<p>x</p>")))
        val from = "OEBPS/ch1.xhtml".toByteArray()
        val to = "OEBPS/zz1.xhtml".toByteArray()
        var index = 0
        while (index <= bytes.size - from.size) {
            if (from.indices.all { bytes[index + it] == from[it] }) {
                to.copyInto(bytes, index)
                index += from.size
            } else {
                index += 1
            }
        }

        val row = local.importAndWait(local.pick(bytes, "middlemarch.epub"))
        assertEquals(LocalImport.Stage.Failed(LocalImportError.Damaged), row?.stage)
    }

    /** A book over the limit is too large, and says how large. */
    @Test
    fun tooLarge() = run { local, _ ->
        local.library.importer.maximumSize = 1024
        val url = local.pick("readalong")
        val size = fileOf(url).length()

        val row = local.importAndWait(url)
        assertEquals(LocalImport.Stage.Failed(LocalImportError.TooLarge(size)), row?.stage)
        assertNull(LocalImportError.TooLarge(size).action)
    }

    /** Not enough room says what is needed and what is free, and offers Try Again. */
    @Test
    fun notEnoughSpace() = run { local, _ ->
        local.library.importer.availableSpace = { 1000 }
        local.library.importer.spaceMargin = 0
        val url = local.pick("readalong")
        val size = fileOf(url).length()

        val row = local.importAndWait(url)
        val error = LocalImportError.NotEnoughSpace(size, 1000)
        assertEquals(LocalImport.Stage.Failed(error), row?.stage)
        assertEquals(LocalImportError.Action.TRY_AGAIN, error.action)
        assertEquals("Not enough space on this phone", error.title)

        // Room made, the same row tried again: it is added.
        local.library.importer.availableSpace = { Long.MAX_VALUE / 2 }
        local.library.retry(checkNotNull(row).id)
        local.library.importsSettled()
        assertEquals(1, local.library.books.size)
    }

    /** A read-along needs room for its narration as well as its copy. */
    @Test
    fun narrationNeedsRoom() = run { local, _ ->
        val url = local.pick("readalong")
        val size = fileOf(url).length()
        local.library.importer.spaceMargin = 0
        // Room for the copy, not for the copy and its audio.
        local.library.importer.availableSpace = { size + 10 }

        val row = local.importAndWait(url)
        val error = ((row?.stage as? LocalImport.Stage.Failed)?.error as? LocalImportError.NotEnoughSpace)
            ?: return@run fail("expected a refusal for space, got ${row?.stage}")
        assertTrue(error.needed > size)
    }

    // Notices

    /** Narration this device cannot play is dropped, with a notice. */
    @Test
    fun unplayableNarration() = run { local, _ ->
        val opus = TestEpub.data(
            title = "The Opus Narration",
            chapters = listOf(TestEpub.Chapter("ch1", "One", "<p><span id=\"s0\">Spoken.</span></p>", narrated = listOf("s0"))),
            audio = ByteArray(512), audioMediaType = "audio/opus",
        )

        local.importAndWait(local.pick(opus, "moby-dick.epub"))

        val book = checkNotNull(local.library.books.firstOrNull())
        assertFalse("narration that plays nothing must not be offered", book.hasReadalong)
        assertEquals(listOf(LocalNotice.NARRATION_UNPLAYABLE), book.localCopy?.notices)
        assertEquals(
            "Added without narration. Its audio is in a format this phone can’t play, so the book reads as text only.",
            LocalBooksCopy.notice(LocalNotice.NARRATION_UNPLAYABLE),
        )

        // OK clears it for good.
        local.library.dismissNotice(LocalNotice.NARRATION_UNPLAYABLE, book.uuid)
        assertEquals(true, local.library.books.firstOrNull()?.localCopy?.notices?.isEmpty())
    }

    /** A fixed-layout book is added, with a notice. */
    @Test
    fun fixedLayout() = run { local, _ ->
        val fixed = TestEpub.data(
            title = "A Child's Picture Book",
            chapters = listOf(TestEpub.Chapter("ch1", "One", "<p>Pictures.</p>")),
            metadata = "<meta property=\"rendition:layout\">pre-paginated</meta>",
        )

        local.importAndWait(local.pick(fixed, "verses.epub"))

        val book = checkNotNull(local.library.books.firstOrNull())
        assertEquals(true, book.localCopy?.isFixedLayout)
        assertEquals(listOf(LocalNotice.FIXED_LAYOUT), book.localCopy?.notices)
    }

    // Cancelling, and what a crash leaves

    /** Cancelling mid-copy leaves no trace and no message: the copy is held after its first chunk. */
    @Test
    fun cancelMidCopy() = run { local, _ ->
        val started = AtomicBoolean(false)
        val proceed = CountDownLatch(1)
        val once = AtomicBoolean(false)
        local.library.importer.chunkSize = 256
        local.library.importer.afterChunk = {
            if (once.compareAndSet(false, true)) {
                started.set(true)
                // On the copy's own thread, never the main one: this is the hold.
                proceed.await(10, TimeUnit.SECONDS)
            }
        }
        val url = local.pick("readalong")
        local.library.importBooks(listOf(url))
        val id = checkNotNull(local.library.imports.firstOrNull()?.id)

        // Bounded: the copy runs on its own thread and says when it is held.
        assertTrue("the copy never started", waitUntil(10.seconds) { started.get() })
        local.library.cancelImport(id)
        proceed.countDown()
        local.library.importsSettled()

        assertTrue("a cancelled file leaves no row", local.library.imports.isEmpty())
        assertTrue(local.library.books.isEmpty())
        assertTrue("the half-made copy was left in flight", local.incoming().isEmpty())
        assertTrue(local.root.list()?.filter { !it.startsWith(".") }.orEmpty().isEmpty())
    }

    /** A launch clears what a crash left: copies in flight and folders with no row. */
    @Test
    fun crashLeftovers() = run { local, _ ->
        val incoming = LocalBookFiles.incoming(local.root).apply { mkdirs() }
        File(incoming, "${UUID.randomUUID()}.epub").writeText("half")
        val orphan = LocalBookFiles(UUID.randomUUID().toString().lowercase(), local.root)
        orphan.folder.mkdirs()
        orphan.epub.writeText("book")

        local.library.load()

        assertTrue(local.incoming().isEmpty())
        assertFalse(orphan.folder.exists())
        assertTrue(local.library.isLoaded)
        assertTrue(local.library.books.isEmpty())
    }

    // Removing

    /** Removing takes the book off the list at once, and undo puts it back. */
    @Test
    fun removeAndUndo() = run { local, _ ->
        local.importAndWait(local.pick("alice"))
        val book = checkNotNull(local.library.books.firstOrNull())
        val released = ArrayList<String>()
        local.library.onRemove = { released.add(it) }

        local.library.remove(listOf(book.uuid))
        assertTrue(local.library.books.isEmpty())
        assertEquals("whatever was reading it is let go at once", listOf(book.uuid), released)
        assertEquals(
            "Removed Alice's Adventures in Wonderland. Original kept in your files.",
            local.library.pendingRemoval?.message,
        )
        assertTrue("still the device's until it goes", book.uuid in local.library.uuids)

        local.library.undoRemoval()
        assertEquals(listOf(book.uuid), local.library.books.map { it.uuid })
        assertTrue(local.library.files(book.uuid).epub.exists())
    }

    /** A removal carried out deletes the copy, the place, the marks and the anchor. */
    @Test
    fun removeCommitted() = run { local, _ ->
        local.importAndWait(local.pick("readalong"))
        val book = checkNotNull(local.library.books.firstOrNull())
        val locator = ReadiumLocator(
            href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.2, totalProgression = 0.1),
        )
        assertTrue(local.library.writePosition(locator, 1.0, PositionOrigin.CHOSEN, book.uuid))
        local.library.recordAudioAnchor(AudioAnchor(audioHref = "OEBPS/Audio/track1.mp3", offset = 2.0, writtenAt = 1.0), book.uuid)
        val mark = Annotation(bookUuid = book.uuid, kind = Annotation.Kind.HIGHLIGHT, locator = locator, excerpt = "kept its own record")
        local.library.save(mark)
        LibraryStore(LibraryStore.deviceBooksKey, local.storeDirectory).use { store ->
            val saved = waitUntil(2.seconds) { store.annotations(book.uuid).size == 1 }
            assertTrue("the highlight has to be on disk for its deletion to mean anything", saved)
            val forgotten = ArrayList<String>()
            local.library.onForget = { forgotten.add(it) }
            // Something written to the folder after import, as narration would be.
            val narration = local.library.files(book.uuid).narration.apply { mkdirs() }
            File(narration, "a.mp3").writeText("audio")

            local.library.remove(listOf(book.uuid))
            local.library.commitPendingRemoval()

            assertEquals(listOf(book.uuid), forgotten)
            assertFalse(local.library.files(book.uuid).folder.exists())
            val gone = waitUntil(2.seconds) {
                store.book(book.uuid) == null && store.annotations(book.uuid).isEmpty() && store.audioAnchor(book.uuid) == null
            }
            assertTrue("the row, highlights or anchor outlived the book", gone)
        }
        // And a write arriving now is refused, not written back.
        assertFalse(local.library.writePosition(locator, 2.0, PositionOrigin.CHOSEN, book.uuid))
    }
}
