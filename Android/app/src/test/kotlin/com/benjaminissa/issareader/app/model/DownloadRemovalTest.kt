package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testDownloads
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.download.DownloadManager
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.time.Duration.Companion.milliseconds

/**
 * What a removal takes with it, and what it must not. Ported from
 * `DownloadRemovalTests.swift`.
 *
 * Android keeps a book's publisher faces in memory, so there is no
 * `Fonts/<uuid>/` for a removal to release; where the Swift suite watched an
 * extracted face as the canary for "the book's derived files were released",
 * these watch the question index's removal ([BookIndexes.remove]), which the
 * same rule decides.
 */
class DownloadRemovalTest : AppSuite() {
    private fun freshUuid(): String = UUID.randomUUID().toString()

    private fun booksDirectory(): File = BookContentService.defaultDirectory().apply { mkdirs() }

    private fun plant(uuid: String, format: BookContentService.Format, bytes: Int = 32): File =
        BookContentService.localUrl(booksDirectory(), uuid, format).apply { writeBytes(ByteArray(bytes)) }

    /** Which books' derived files a removal released, through the question index's hook. */
    private class RecordingIndexes : BookIndexes {
        val removed = mutableListOf<String>()
        override fun remove(bookUuid: String) {
            synchronized(removed) { removed.add(bookUuid) }
        }

        fun released(uuid: String) = synchronized(removed) { uuid in removed }
    }

    /** A book with no audio behind it: what is under test is whether anything asked before deleting. */
    private fun silentEngine(scope: CoroutineScope) = AudiobookCoordinator(
        manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Dracula")),
            readingOrder = listOf(AudiobookManifest.Track(href = "track1.mp3", type = "audio/mpeg", duration = 60.0)),
        ),
        source = AudiobookCoordinator.Source.Files(emptyMap()),
        player = AudioPlayer(ScriptedBackend()),
        scope = scope,
    )

    /** A reader narrating a book, without a real EPUB behind it: `play()` notifies its observers whether or not anything loaded. */
    private fun narrating(app: AppModel, book: Book, server: StubServer): ReaderModel {
        val model = app.reader(book, server.session())
        model.attachNarration(
            SmilTimeline(
                listOf(
                    SmilEntry(
                        fragmentId = "ch01-s0", textHref = "OEBPS/ch01.xhtml", audioHref = "OEBPS/Audio/track1.mp3",
                        start = 0.0, end = 4.0, cumulativeEnd = 4.0,
                    ),
                ),
            ),
            emptyMap(),
        )
        model.readalong?.player?.play()
        return model
    }

    private fun run(body: suspend (AppModel, CoroutineScope, StubServer) -> Unit) = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        try {
            body(testApp(scope), scope, server)
        } finally {
            server.close()
            scope.close()
        }
    }

    /** Removing one edition leaves the other on the device. */
    @Test
    fun removingOneEditionLeavesTheOther() = run { app, _, _ ->
        val uuid = freshUuid()
        val ebook = plant(uuid, BookContentService.Format.EBOOK)
        val readaloud = plant(uuid, BookContentService.Format.READALOUD, 64)
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)

        app.removeDownload(book, BookContentService.Format.EBOOK)

        assertFalse(ebook.exists())
        assertTrue("the reader asked for one edition to go, not the book", readaloud.exists())
        assertTrue("the book is still downloaded", uuid in app.downloadedUuids)
    }

    /** A removal leaves the rating, the position and the annotations alone. */
    @Test
    fun removalLeavesTheReadersOwnDataAlone() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        val book = SharedFixtures.book("Dracula", uuid = uuid, status = "Reading", progress = 0.42, positionTimestamp = 99.0)
        app.books = listOf(book)
        app.rebuildDerived()
        app.ratings = app.ratings + (uuid to 4.0)
        val directory = temporaryDirectory("removal-store")
        val store = LibraryStore("removal-test-${UUID.randomUUID()}", directory)
        store.save(
            Annotation(
                bookUuid = uuid, kind = Annotation.Kind.HIGHLIGHT,
                locator = ReadiumLocator(href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml"),
                excerpt = "Listen to them, the children of the night.",
            ),
        )
        app.useStore(store)

        app.removeDownload(book, BookContentService.Format.EBOOK)

        assertFalse(file.exists())
        assertEquals(4.0, app.ratings[uuid])
        assertEquals(99.0, app.books.first().position?.timestamp)
        val progression = app.bookByUuid[uuid]?.progress
        assertTrue(progression != null && abs(progression - 0.42) < 0.0001)
        var lost = false
        repeat(20) {
            if (runCatching { store.annotations(uuid) }.getOrDefault(emptyList()).size != 1) lost = true
            delay(25.milliseconds)
        }
        assertFalse("annotations are the reader's, not the download's", lost)
        directory.deleteRecursively()
    }

    /** Removing a book that is playing stops it first. */
    @Test
    fun removingStopsTheAudiobook() = run { app, scope, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.READALOUD)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid))

        app.removeDownload(uuid, BookContentService.Format.READALOUD)

        assertNull("the engine was reading out of the file that just went", app.listening)
        assertNull(app.listeningBook)
        assertFalse(engine.player.isPlaying)
        assertFalse(file.exists())
    }

    /** Removing a book being narrated stops the narration first. */
    @Test
    fun removingStopsTheNarration() = run { app, _, server ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.READALOUD)
        app.refreshDownloadedSet()
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = narrating(app, book, server)
        assertSame("the setup has to have claimed narration", model, app.reader)

        app.removeDownload(uuid, BookContentService.Format.READALOUD)

        assertNull("nothing may narrate a book whose text has gone", app.reader)
        assertEquals(false, model.readalong?.player?.isPlaying ?: false)
        assertFalse(file.exists())
    }

    /** The sweep stops a book whose file went behind the app's back. */
    @Test
    fun theSweepStopsAPlayingBook() = run { app, scope, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.READALOUD)
        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)
        val engine = silentEngine(scope)
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid))

        file.delete()
        app.refreshDownloadedSet()

        assertNull("the sweep deletes what this was playing out of", app.listening)
        assertFalse(engine.player.isPlaying)
    }

    /** Removing the ebook leaves an audiobook playing. */
    @Test
    fun removingTheEbookLeavesTheAudiobookPlaying() = run { app, scope, _ ->
        val uuid = freshUuid()
        val ebook = plant(uuid, BookContentService.Format.EBOOK)
        val audiobook = plant(uuid, BookContentService.Format.AUDIOBOOK, 64)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), BookContentService.Format.AUDIOBOOK)

        app.removeDownload(uuid, BookContentService.Format.EBOOK)

        assertSame("the file that went is not the file it was reading", engine, app.listening)
        assertTrue("a drive must not end because a book was tidied up", engine.player.isPlaying)
        assertFalse(ebook.exists())
        assertTrue(audiobook.exists())
    }

    /** Removing the ebook leaves a narration playing. */
    @Test
    fun removingTheEbookLeavesTheNarrationPlaying() = run { app, _, server ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        val readaloud = plant(uuid, BookContentService.Format.READALOUD, 64)
        app.refreshDownloadedSet()
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = narrating(app, book, server)

        app.removeDownload(uuid, BookContentService.Format.EBOOK)

        assertSame("the read-along it is narrating from is still on the device", model, app.reader)
        assertEquals(true, model.readalong?.player?.isPlaying)
        assertTrue(readaloud.exists())
    }

    /** Removing the audiobook stops an engine playing the single upload. */
    @Test
    fun removingTheAudiobookStopsTheEngineReadingIt() = run { app, scope, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        val audiobook = plant(uuid, BookContentService.Format.AUDIOBOOK, 64)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), BookContentService.Format.AUDIOBOOK)

        app.removeDownload(uuid, BookContentService.Format.AUDIOBOOK)

        assertNull("the engine was reading the file that just went", app.listening)
        assertFalse(engine.player.isPlaying)
        assertFalse(audiobook.exists())
    }

    /** Removing the audiobook leaves an engine playing the read-along's chunks. */
    @Test
    fun removingTheAudiobookLeavesTheChunkEngineAlone() = run { app, scope, _ ->
        val uuid = freshUuid()
        val readaloud = plant(uuid, BookContentService.Format.READALOUD)
        plant(uuid, BookContentService.Format.AUDIOBOOK, 64)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), BookContentService.Format.READALOUD)

        app.removeDownload(uuid, BookContentService.Format.AUDIOBOOK)

        assertSame("its chunks come out of the read-along, not this", engine, app.listening)
        assertTrue(engine.player.isPlaying)
        assertTrue(readaloud.exists())
    }

    /** Removing the read-along stops both engines. */
    @Test
    fun removingTheReadaloudStopsBoth() = run { app, scope, server ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        plant(uuid, BookContentService.Format.READALOUD, 64)
        app.refreshDownloadedSet()
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        // Narration first: its start stops listening on its way in.
        val model = narrating(app, book, server)
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, book, BookContentService.Format.READALOUD)

        app.removeDownload(uuid, BookContentService.Format.READALOUD)

        assertNull("the chunks it was playing are extracted from this file", app.listening)
        assertFalse(engine.player.isPlaying)
        assertNull("and the text it was narrating is this file", app.reader)
        assertEquals(false, model.readalong?.player?.isPlaying ?: false)
    }

    /** A streamed book survives every removal. */
    @Test
    fun aStreamedBookSurvivesEveryRemoval() = run { app, scope, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        plant(uuid, BookContentService.Format.AUDIOBOOK, 64)
        plant(uuid, BookContentService.Format.READALOUD, 96)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), null)

        app.removeDownload(uuid, BookContentService.Format.EBOOK)
        assertSame("a stream is not read out of anything on this device", engine, app.listening)

        app.removeDownload(uuid, BookContentService.Format.AUDIOBOOK)
        assertSame("nor out of the edition it is named after", engine, app.listening)
        assertTrue(engine.player.isPlaying)
    }

    /** The sweep stops both engines whatever they were reading. */
    @Test
    fun theSweepStopsBothEngines() = run { app, scope, server ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = narrating(app, book, server)
        val engine = silentEngine(scope)
        engine.player.play()
        // A format no named removal of the file below would have touched.
        app.installListening(engine, book, BookContentService.Format.AUDIOBOOK)

        file.delete()
        app.refreshDownloadedSet()

        assertNull("the sweep cannot say which file went, so none is safe", app.listening)
        assertFalse(engine.player.isPlaying)
        assertNull(app.reader)
        assertEquals(false, model.readalong?.player?.isPlaying ?: false)
    }

    /** A removal clears a start that has claimed the book but not attached it. */
    @Test
    fun aRemovalClearsAnUnattachedStart() = run { app, _, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        val readaloud = plant(uuid, BookContentService.Format.READALOUD, 64)
        app.refreshDownloadedSet()
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.claimListeningStart(book, BookContentService.Format.READALOUD)

        app.removeDownload(uuid, BookContentService.Format.READALOUD)

        assertNull("a start that has not attached still owns the book it is about to play", app.startingListeningBook)
        assertNull("and nothing may be installed for it afterwards", app.listening)
        assertFalse(readaloud.exists())
    }

    /** A removal of another edition leaves the claim alone. */
    @Test
    fun aRemovalOfAnotherEditionLeavesTheClaim() = run { app, _, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.AUDIOBOOK)
        val readaloud = plant(uuid, BookContentService.Format.READALOUD, 64)
        app.refreshDownloadedSet()
        val book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true)
        app.claimListeningStart(book, BookContentService.Format.READALOUD)

        app.removeDownload(uuid, BookContentService.Format.AUDIOBOOK)

        assertEquals("the chunks it is extracting come out of the read-along, not this", uuid, app.startingListeningBook)
        assertTrue(readaloud.exists())
    }

    /** A file that went behind the model's back takes its question index with it. */
    @Test
    fun reconcileDropsTheIndexOfADepartedDownload() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = BookContentService.localUrl(booksDirectory(), uuid, BookContentService.Format.EBOOK)
        Fixtures.epub("alice.epub").copyTo(file, overwrite = true)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)

        file.delete()
        app.refreshDownloadedSet()

        assertFalse(uuid in app.downloadedUuids)
        assertTrue("the index outlived the book it was built from", indexes.released(uuid))
    }

    /** Removing the last edition and reconciling it are the same removal, run twice. */
    @Test
    fun removalIsIdempotentWithTheSweep() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        app.removeDownload(SharedFixtures.book("Dracula", uuid = uuid), BookContentService.Format.EBOOK)

        assertFalse(file.exists())
        assertTrue(indexes.released(uuid))
        assertFalse(uuid in app.downloadedUuids)
    }

    /** Removing one of two editions keeps the derived files of the other. */
    @Test
    fun removingOneEditionKeepsTheBooksDerivedFiles() = run { app, _, _ ->
        val uuid = freshUuid()
        val ebook = BookContentService.localUrl(booksDirectory(), uuid, BookContentService.Format.EBOOK)
        Fixtures.epub("alice.epub").copyTo(ebook, overwrite = true)
        val readaloud = plant(uuid, BookContentService.Format.READALOUD, 64)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        app.removeDownload(uuid, BookContentService.Format.EBOOK)

        assertFalse("the edition asked for is the one that goes", ebook.exists())
        assertTrue(readaloud.exists())
        assertTrue("the book has not departed", uuid in app.downloadedUuids)
        delay(300.milliseconds)
        assertFalse("the index was built from text that is still on the device", indexes.released(uuid))

        // And when the last edition carrying text goes, it does go.
        app.removeDownload(uuid, BookContentService.Format.READALOUD)
        assertTrue(indexes.released(uuid))
    }

    /** An audiobook left on the device does not keep the book's derived files alive. */
    @Test
    fun anAudiobookIsNotTextOnTheDevice() = run { app, _, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        val audiobook = plant(uuid, BookContentService.Format.AUDIOBOOK, 64)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        app.removeDownload(uuid, BookContentService.Format.EBOOK)

        assertTrue("the edition not asked for stays", audiobook.exists())
        assertTrue("nothing left on the device has any text in it", indexes.released(uuid))
    }

    /**
     * A downloads directory that cannot be read is not an empty library. The
     * suites run as root, which no permission bit stops, so the directory is
     * made unreadable by putting a file where it was.
     */
    @Test
    fun anUnreadableDirectoryIsNotADeparture() = run { app, _, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)

        val directory = booksDirectory()
        val aside = File(directory.parentFile, "Books-aside-${UUID.randomUUID()}")
        assertTrue(directory.renameTo(aside))
        directory.writeText("not a directory")
        try {
            app.refreshDownloadedSet()

            assertTrue("the last set it could read is a better answer than a wrong one", uuid in app.downloadedUuids)
            assertFalse("the sweep released a book that never left", indexes.released(uuid))
        } finally {
            directory.delete()
            aside.renameTo(directory)
        }
    }

    /** A removal inside its undo window has not touched the disk yet. */
    @Test
    fun undoWindowDefersTheDeletion() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)

        assertEquals(uuid, app.pendingRemoval?.bookUuid)
        assertTrue("undo must never have to fetch anything back", file.exists())

        app.undoPendingRemoval()
        assertNull(app.pendingRemoval)
        assertTrue(file.exists())
    }

    /** The window closing deletes what it was holding. */
    @Test
    fun theWindowCommits() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
        app.commitPendingRemoval()

        assertNull(app.pendingRemoval)
        assertFalse(file.exists())
    }

    /** A second removal commits the first rather than losing it. */
    @Test
    fun aSecondRemovalCommitsTheFirst() = run { app, _, _ ->
        val first = freshUuid()
        val second = freshUuid()
        val firstFile = plant(first, BookContentService.Format.EBOOK)
        val secondFile = plant(second, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(first, BookContentService.Format.EBOOK, "One", undoWindowMillis = 600_000)
        app.removeDownload(second, BookContentService.Format.EBOOK, "Two", undoWindowMillis = 600_000)

        assertFalse("the first window closed when the second opened", firstFile.exists())
        assertTrue(secondFile.exists())
        assertEquals(second, app.pendingRemoval?.bookUuid)
        app.commitPendingRemoval()
    }

    /** An edition inside its undo window is off the device everywhere. */
    @Test
    fun theUndoWindowIsVisibleToEverySurface() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)
        assertTrue(app.isDownloaded(uuid, BookContentService.Format.EBOOK))

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)

        assertFalse("the car was still being offered a book about to be deleted", uuid in app.downloadedUuids)
        assertFalse(app.isDownloaded(uuid, BookContentService.Format.EBOOK))
        assertTrue("and the bytes are still there, which is the point", file.exists())

        app.undoPendingRemoval()
        assertTrue("undo puts it back with no fetch", uuid in app.downloadedUuids)
        assertTrue(app.isDownloaded(uuid, BookContentService.Format.EBOOK))
    }

    /** A book with a second edition stays on the device during the window. */
    @Test
    fun aSecondEditionKeepsTheBookOnTheShelf() = run { app, _, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.EBOOK)
        plant(uuid, BookContentService.Format.READALOUD, 64)
        app.refreshDownloadedSet()

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)

        assertTrue("the read-along is still on the device", uuid in app.downloadedUuids)
        assertFalse("but this edition is going", app.isDownloaded(uuid, BookContentService.Format.EBOOK))
        assertTrue(app.isDownloaded(uuid, BookContentService.Format.READALOUD))
        app.commitPendingRemoval()
    }

    /** Cancelling a transfer leaves the book's other edition untouched. */
    @Test
    fun cancellingATransferIsNotABookRemoval() = run { app, _, _ ->
        val uuid = freshUuid()
        val ebook = plant(uuid, BookContentService.Format.EBOOK)
        val indexes = RecordingIndexes()
        app.ask = indexes

        app.refreshDownloadedSet()
        assertTrue(uuid in app.downloadedUuids)

        // The read-along started by accident: no file for it, which is what a transfer still running looks like.
        app.cancelDownload(DownloadManager.Job(uuid, BookContentService.Format.READALOUD))

        assertTrue("the edition already on the device is not what was cancelled", ebook.exists())
        assertFalse("the derived files belong to the ebook, which nobody asked to remove", indexes.released(uuid))
        assertTrue(uuid in app.downloadedUuids)
    }

    /** Starting a download takes back a removal still inside its window. */
    @Test
    fun startingADownloadCancelsAPendingRemoval() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
        assertEquals(uuid, app.pendingRemoval?.bookUuid)

        // No session, so no transfer starts; the tap is the statement.
        app.resumeDownload(DownloadManager.Job(uuid, BookContentService.Format.EBOOK))

        assertNull("the window is still armed over a book being fetched", app.pendingRemoval)
        app.commitPendingRemoval()
        assertTrue("the window closed on a removal the reader had reversed", file.exists())
    }

    /** Starting a different download leaves the window alone. */
    @Test
    fun aDifferentDownloadLeavesTheWindowAlone() = run { app, _, _ ->
        val removed = freshUuid()
        val other = freshUuid()
        val file = plant(removed, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(removed, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
        app.resumeDownload(DownloadManager.Job(other, BookContentService.Format.EBOOK))
        assertEquals(removed, app.pendingRemoval?.bookUuid)

        // And the same book in a different edition is a different job too.
        app.resumeDownload(DownloadManager.Job(removed, BookContentService.Format.READALOUD))
        assertEquals(removed, app.pendingRemoval?.bookUuid)

        app.commitPendingRemoval()
        assertFalse(file.exists())
    }

    /** A refresh inside the undo window keeps the book's narration and what is playing it. */
    @Test
    fun aRefreshInsideTheWindowKeepsTheNarration() = run { app, scope, _ ->
        val uuid = freshUuid()
        plant(uuid, BookContentService.Format.READALOUD)
        val narration = AudioExtraction.defaultDirectory(uuid)
        narration.mkdirs()
        File(narration, "chunk-0001.mp3").writeBytes(ByteArray(16))
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid))

        app.removeDownload(uuid, BookContentService.Format.READALOUD, "Dracula", undoWindowMillis = 600_000)
        // Another transfer finishing, say.
        app.refreshDownloadedSet()

        assertTrue("the narration was deleted with its file still on disk", narration.exists())
        assertSame("the book was stopped as if its file had gone", engine, app.listening)
        assertFalse("the window still holds the book off every shelf", uuid in app.downloadedUuids)

        app.undoPendingRemoval()
        assertTrue(uuid in app.downloadedUuids)
        assertTrue("undo has nothing to extract again", narration.exists())
        app.stopListening(null)
    }

    /** The window closing on a book's last edition leaves a stream of it playing. */
    @Test
    fun theWindowClosingLeavesAStreamPlaying() = run { app, scope, _ ->
        val uuid = freshUuid()
        val ebook = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), null)

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
        app.commitPendingRemoval()

        assertFalse(ebook.exists())
        assertFalse(uuid in app.downloadedUuids)
        assertSame("a removal silenced a stream, which reads nothing here", engine, app.listening)
        assertTrue(engine.player.isPlaying)
        app.stopListening(null)
    }

    /** Signing out closes an open undo window first. */
    @Test
    fun signingOutCommitsAPendingRemoval() = run { app, _, _ ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()

        app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
        app.signOut(keepDownloads = true)

        assertNull(app.pendingRemoval)
        assertFalse(file.exists())
    }

    /** Asking for an edition inside its undo window takes the removal back and fetches nothing. */
    @Test
    fun askingInsideTheWindowFetchesNothing() = run { app, scope, server ->
        val uuid = freshUuid()
        val file = plant(uuid, BookContentService.Format.EBOOK)
        val session = server.session(keychain = TestTokens())
        app.session = session
        val scratch = temporaryDirectory("download-removal")
        val manager = testDownloads(session.serverUrl, session.tokenProvider, scope, scratch)
        app.useDownloads(manager)
        app.meteredNetworkOverride = false
        val plain = SharedFixtures.book("Dracula", uuid = uuid)
        val book = plain.copy(ebook = plain.ebook?.copy(fileSize = 1L shl 60))
        app.books = listOf(book)
        app.rebuildDerived()
        try {
            app.refreshDownloadedSet()
            app.removeDownload(uuid, BookContentService.Format.EBOOK, "Dracula", undoWindowMillis = 600_000)
            assertFalse(app.isDownloaded(book, BookContentService.Format.EBOOK))

            // What the reader's open does: wait for the edition.
            val opened = app.downloadAndWait(book, BookContentService.Format.EBOOK) { _, _ -> }

            val job = DownloadManager.Job(uuid, BookContentService.Format.EBOOK)
            assertNull("a transfer was started for a file already on the device", manager.state(job))
            assertNull("the removal was not taken back", app.pendingRemoval)
            assertTrue(file.exists())
            assertEquals(file.name, opened.name)
            assertTrue(app.isDownloaded(book, BookContentService.Format.EBOOK))
        } finally {
            manager.stop()
            scratch.deleteRecursively()
        }
    }

    /** Cancelling a transfer that landed leaves a stream of the book playing. */
    @Test
    fun cancellingALandedTransferLeavesAStreamPlaying() = run { app, scope, _ ->
        val uuid = freshUuid()
        app.refreshDownloadedSet()
        val landed = plant(uuid, BookContentService.Format.EBOOK)
        app.refreshDownloadedSet()
        val engine = silentEngine(scope)
        engine.player.play()
        app.installListening(engine, SharedFixtures.book("Dracula", uuid = uuid), null)

        app.cancelDownload(DownloadManager.Job(uuid, BookContentService.Format.EBOOK))

        assertFalse("the cancelled transfer's file stays only if nothing removes it", landed.exists())
        assertSame("a cancelled ebook silenced a stream of its book", engine, app.listening)
        assertTrue(engine.player.isPlaying)
        app.stopListening(null)
    }
}
