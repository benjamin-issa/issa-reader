package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.ScriptedServer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.TestTokens
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.local.LocalBooksWiring
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.LocalBookFiles
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.time.Duration.Companion.milliseconds

/**
 * The way out writes where the audiobook is, and flushes the log before it
 * can be held up by the network. Ported from `ListeningFlushTests.swift`.
 */
class ListeningFlushTest : AppSuite() {
    private val uuid = "55555555-5555-4555-8555-555555555555"

    private class Fixture(
        val app: AppModel,
        val store: LibraryStore,
        val directory: File,
        val book: Book,
        val coordinator: AudiobookCoordinator,
        val scope: CoroutineScope,
        val uuid: String,
    ) {
        suspend fun queuedPositions(): List<MutationDrain.PositionPayload> = MutationQueue(store).use { it.pending() }
            .filter { it.kind == MutationQueue.Kind.POSITION && it.bookUuid == uuid }
            .map { IssaJson.decodeFromString(MutationDrain.PositionPayload.serializer(), it.payload.decodeToString()) }

        fun tearDown() {
            app.stopListening(null)
            directory.deleteRecursively()
            scope.close()
        }
    }

    /**
     * Three tracks of a thousand seconds, half a track in, with the writer
     * armed on an interval this test never reaches, so every write seen here
     * is the flush's.
     */
    private fun listening(): Fixture {
        val scope = testScope()
        val app = testApp(scope)
        val directory = temporaryDirectory("listening-flush")
        val store = LibraryStore("listening-flush", directory)
        app.useStore(store)
        val book = SharedFixtures.book("A Book", uuid = uuid, audiobook = true)
        app.books = listOf(book)
        app.rebuildDerived()
        val coordinator = AudiobookCoordinator(
            manifest = AudiobookManifest(
                metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book")),
                readingOrder = (0 until 3).map { AudiobookManifest.Track(href = "t$it.mp3", type = "audio/mpeg", duration = 1_000.0) },
            ),
            // A source nothing can open, as Swift's /dev/null was: the clock is what drives this.
            source = AudiobookCoordinator.Source.Local(File(directory, "missing.mp3")),
            player = AudioPlayer(ScriptedBackend()),
            scope = scope,
        )
        app.installListening(coordinator, book, BookContentService.Format.AUDIOBOOK)
        app.watchListeningProgress(book, coordinator, intervalMillis = 3_600_000)
        // Half a track of listening since the writer was armed.
        coordinator.player.onTimeUpdate?.invoke(500.0)
        return Fixture(app, store, directory, book, coordinator, scope, uuid)
    }

    /** Quitting while listening writes the audiobook's position. */
    @Test
    fun theFlushWritesTheListeningPosition() = mainTest {
        val fixture = listening()
        try {
            val progress = fixture.coordinator.bookProgress
            assertTrue("the clock has to have moved for there to be anything to lose", progress > 0.1)

            fixture.app.flushOpenReaders()

            val written = fixture.queuedPositions()
            assertEquals("the listening position was written nowhere", 1, written.size)
            val locator = written.first().locator
            assertTrue("on the audio clock, as the writer writes it", locator.isAudioScaled)
            val total = checkNotNull(locator.totalProgression)
            assertTrue(abs(total - progress) < 0.0001)
            val shown = fixture.app.bookByUuid[uuid]?.progress
            assertTrue(shown?.let { abs(it - progress) < 0.0001 } == true)
        } finally {
            fixture.tearDown()
        }
    }

    /** A book that has not moved since the last write is not written again. */
    @Test
    fun aBookThatHasNotMovedIsNotWrittenAgain() = mainTest {
        val fixture = listening()
        try {
            fixture.app.flushOpenReaders()
            val first = checkNotNull(fixture.queuedPositions().firstOrNull())
            delay(50.milliseconds)
            fixture.app.flushOpenReaders()
            val second = checkNotNull(fixture.queuedPositions().firstOrNull())

            assertEquals("a paused book was stamped with a new time", first.timestamp, second.timestamp, 0.0)
        } finally {
            fixture.tearDown()
        }
    }

    /** Nothing is written for a book whose writer is not armed. */
    @Test
    fun nothingIsWrittenWithoutAnArmedWriter() = mainTest {
        val fixture = listening()
        try {
            // The engine still installed, its writer gone: what a hand-off leaves.
            fixture.app.stopListening(null)
            fixture.app.installListening(fixture.coordinator, fixture.book, BookContentService.Format.AUDIOBOOK)
            assertFalse(fixture.app.isWritingListeningPosition)

            fixture.app.flushOpenReaders()

            assertTrue(fixture.queuedPositions().isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /** F04#4: the log is flushed before the drain sends anything. */
    @Test
    fun theLogIsFlushedBeforeTheDrain() = mainTest {
        val scope = testScope()
        val server = ScriptedServer()
        val directory = temporaryDirectory("log-flush")
        try {
            val store = LibraryStore(server.url.toString(), directory)
            MutationQueue(store).use {
                it.enqueue(
                    MutationQueue.Kind.POSITION, uuid,
                    IssaJson.encodeToString(
                        MutationDrain.PositionPayload.serializer(),
                        MutationDrain.PositionPayload(
                            ReadiumLocator(
                                href = "OEBPS/ch01.xhtml", type = "application/xhtml+xml",
                                locations = ReadiumLocator.Locations(progression = 0.2, totalProgression = 0.2),
                            ),
                            10.0,
                        ),
                    ).encodeToByteArray(),
                    supersedes = 10.0,
                )
            }
            val tokens = TestTokens()
            val app = testApp(scope, keychain = tokens)
            app.useStore(store)
            app.session = server.session(storing = "token-A", keychain = tokens)
            val sentAtEachFlush = ArrayList<Int>()
            app.logFlush = { synchronized(sentAtEachFlush) { sentAtEachFlush.add(server.requests().size) } }

            app.flushOpenReaders()

            assertTrue(
                "the drain has to have sent the queued write",
                server.requests().any { it.method == "POST" && it.path == Endpoint.positions(uuid) },
            )
            assertEquals("the log was first flushed after the drain had already gone to the network", 0, sentAtEachFlush.firstOrNull())
            assertTrue("and again at the end, for what the drain logged", sentAtEachFlush.size >= 2)
        } finally {
            server.close()
            directory.deleteRecursively()
            scope.close()
        }
    }
}

/**
 * An account's exit keeps the device's own books' per-book state even when it
 * runs before the local library has finished loading. Ported from
 * `LocalKeptSetTests.swift`.
 */
class LocalKeptSetTest : AppSuite() {
    /** An exit before the local library has loaded keeps the books on the disk. */
    @Test
    fun anExitBeforeTheLoadKeepsTheDisksBooks() = mainTest {
        val scope = testScope()
        val sets = ArrayList<Set<String>>()
        val centre = SignOutCentre()
        centre.observe { kept -> sets.add(kept) }
        val app = testApp(scope, centre = centre)
        app.currentBookPublisher = CurrentBookPublisher(scope)
        val storage = temporaryDirectory("kept-set")
        try {
            app.storageRoot = storage
            // A book the reader added, on the disk where the library keeps it,
            // and a library that has not read its store yet.
            val local = UUID.randomUUID().toString().lowercase()
            val files = LocalBookFiles(local, File(storage, "Local"))
            files.folder.mkdirs()
            files.epub.writeText("epub")
            // And the half-finished import `load()` sweeps, which is no book.
            LocalBookFiles.incoming(File(storage, "Local")).mkdirs()
            app.localBookUuids = { emptySet() }

            app.signOut(keepDownloads = true)

            assertEquals("the exit has to have told the observers", 1, sets.size)
            assertTrue("a book on the device was purged because the library had not loaded yet", local in sets[0])
            assertFalse(".incoming" in sets[0])
        } finally {
            storage.deleteRecursively()
            scope.close()
        }
    }

    /** An exit before the local library has loaded keeps a book whose file is missing. */
    @Test
    fun anExitBeforeTheLoadKeepsABookWithoutItsFile() = mainTest {
        val scope = testScope()
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("readalong"))
            val book = checkNotNull(local.library.books.firstOrNull())
            // The backup brought back the store and not the copy.
            local.library.files(book.uuid).folder.deleteRecursively()
            val relaunched = local.relaunched()

            val sets = ArrayList<Set<String>>()
            val centre = SignOutCentre()
            centre.observe { kept -> sets.add(kept) }
            val app = testApp(scope, centre = centre)
            app.currentBookPublisher = CurrentBookPublisher(scope)
            app.storageRoot = local.base
            val settings = PlaybackSettingsForTests.make(centre = centre)
            LocalBooksWiring.connect(app, relaunched, settings, ask = null, scope = scope)
            assertFalse("the exit has to overtake the launch's load", relaunched.isLoaded)

            app.signOut(keepDownloads = true)

            assertEquals("the exit has to have told the observers", 1, sets.size)
            assertTrue("a book restored without its file was purged because the library had not loaded yet", book.uuid in sets[0])
            relaunched.cancelAllImports()
        } finally {
            local.tearDown()
            scope.close()
        }
    }
}
