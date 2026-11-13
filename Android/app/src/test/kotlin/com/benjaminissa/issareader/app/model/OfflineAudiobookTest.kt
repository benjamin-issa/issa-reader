package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * A downloaded audiobook plays with no server. Listen used to ask the server
 * for the manifest before it looked at the file, so a book saved for offline
 * listening said "check that you're on the same network" and never opened.
 */
class OfflineAudiobookTest : AppSuite() {
    /** Two seconds of 8 kHz mono silence: a file the frame walk can measure. */
    private fun wave(): ByteArray {
        val data = ByteArray(16_000)
        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray()).putInt(36 + data.size).put("WAVE".toByteArray())
        header.put("fmt ".toByteArray()).putInt(16).putShort(1).putShort(1).putInt(8_000).putInt(8_000).putShort(1).putShort(8)
        header.put("data".toByteArray()).putInt(data.size)
        return header.array() + data
    }

    private class Fixture(val uuid: String = UUID.randomUUID().toString()) {
        val server = StubServer { Answer(503, "{}") }
        val file: File = BookContentService.localUrl(
            BookContentService.defaultDirectory().also { it.mkdirs() }, uuid, BookContentService.Format.AUDIOBOOK,
        )
        fun clean() {
            server.close()
            BookContentService.removeDownload(uuid, BookContentService.Format.AUDIOBOOK)
        }
    }

    private suspend fun listen(fixture: Fixture, scope: kotlinx.coroutines.CoroutineScope): AppModel {
        val app = testApp(scope)
        app.session = fixture.server.session()
        app.serverAddress = fixture.server.url.toString()
        val book = SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true)
        app.startListening(book, NowPlayingController(scope), PlaybackSettingsForTests.make())
        return app
    }

    /** A download from before manifests were kept: one playable file, the server unreachable. */
    @Test
    fun aDownloadWithNoSavedManifestPlaysOffline() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listen(fixture, scope)

            assertNull("listening said: ${app.listeningError}", app.listeningError)
            assertEquals(fixture.uuid, app.listeningBook?.uuid)
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** With the manifest beside the file, the server is not asked at all. */
    @Test
    fun aDownloadWithItsManifestNeedsNoServer() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val manifest = AudiobookManifest(
                AudiobookManifest.Metadata(title = mapOf("und" to "Offline")),
                listOf(AudiobookManifest.Track(href = "one.mp3", duration = 2.0)),
            )
            BookContentService.saveManifest(manifest, fixture.uuid)
            assertNotNull(BookContentService.savedManifest(fixture.uuid))

            val app = listen(fixture, scope)

            assertNull("listening said: ${app.listeningError}", app.listeningError)
            assertEquals(fixture.uuid, app.listeningBook?.uuid)
            assertTrue("the server was asked: ${fixture.server.requests()}", fixture.server.requests().none { it.path.endsWith("/listen") })
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A book that is not downloaded still needs the server, and says so. */
    @Test
    fun aBookNotDownloadedStillNeedsTheServer() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            val app = listen(fixture, scope)
            assertNotNull(app.listeningError)
            assertNull(app.listeningBook)
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** The manifest goes with the file, and is not kept for a file that is not there. */
    @Test
    fun theManifestGoesWithTheDownload() {
        val fixture = Fixture()
        try {
            val manifest = AudiobookManifest(AudiobookManifest.Metadata(), listOf(AudiobookManifest.Track(href = "a", duration = 1.0)))
            BookContentService.saveManifest(manifest, fixture.uuid)
            assertNull("kept with no file beside it", BookContentService.savedManifest(fixture.uuid))

            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(manifest, fixture.uuid)
            assertNotNull(BookContentService.savedManifest(fixture.uuid))
            assertTrue(fixture.uuid in BookContentService.downloadedBookUuids())

            BookContentService.removeDownload(fixture.uuid, BookContentService.Format.AUDIOBOOK)
            assertNull(BookContentService.savedManifest(fixture.uuid))
            assertFalse(fixture.uuid in BookContentService.downloadedBookUuids())
        } finally {
            fixture.clean()
        }
    }

    /**
     * Listen on the book already playing is a press of Play, and a press reopens
     * a file that would not play. It called the player directly, which refuses a
     * dead item and played nothing.
     */
    @Test
    fun listenOverADeadItemReopensTheFile() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            val app = testApp(scope)
            app.session = fixture.server.session()
            app.serverAddress = fixture.server.url.toString()
            val book = SharedFixtures.book("Dead", uuid = fixture.uuid, audiobook = true)
            val coordinator = AudiobookCoordinator(
                manifest = AudiobookManifest(
                    AudiobookManifest.Metadata(title = mapOf("und" to "Dead")),
                    listOf(AudiobookManifest.Track(href = "one.wav", duration = 2.0)),
                ),
                source = AudiobookCoordinator.Source.Local(fixture.file),
                player = AudioPlayer(ScriptedBackend()),
                scope = scope,
            )
            app.installListening(coordinator, book, BookContentService.Format.AUDIOBOOK)
            coordinator.start(0.0)
            assertTrue("the file was not there, so the item is dead", coordinator.player.itemHasFailed)

            fixture.file.writeBytes(wave())
            app.startListening(book, NowPlayingController(scope), PlaybackSettingsForTests.make())

            assertFalse("Listen played over the dead item", coordinator.player.itemHasFailed)
            assertTrue(coordinator.player.isPlaying)
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    // The stand-in's track name, and what the writer may do with it.

    private suspend fun listenOffline(
        fixture: Fixture,
        scope: kotlinx.coroutines.CoroutineScope,
        progress: Double? = null,
        within: Double? = null,
        storedHref: String = "server-name.mp3",
    ): AppModel {
        val app = testApp(scope)
        val directory = com.benjaminissa.issareader.app.temporaryDirectory("offline-standin")
        app.useStore(com.benjaminissa.issareader.core.store.LibraryStore("offline-standin", directory))
        app.session = fixture.server.session()
        app.serverAddress = fixture.server.url.toString()
        var book = SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true)
        if (progress != null) {
            val locator = com.benjaminissa.issareader.core.model.ReadiumLocator(
                href = storedHref, type = "audio/mpeg",
                locations = com.benjaminissa.issareader.core.model.ReadiumLocator.Locations(
                    progression = within ?: progress, totalProgression = progress,
                ),
            )
            book = book.copy(position = com.benjaminissa.issareader.core.model.StoredPosition(locator = locator, timestamp = 1.0))
        }
        app.books = listOf(book)
        app.startListening(book, NowPlayingController(scope), PlaybackSettingsForTests.make())
        return app
    }

    private fun positionWrites(fixture: Fixture) =
        fixture.server.requests().filter { it.method == "POST" && it.path.endsWith("/positions") }

    /** A kept multi-track manifest means the file is no one track: nothing is written. */
    @Test
    fun aKeptMultiTrackManifestWritesNothingOffline() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(
                AudiobookManifest(
                    AudiobookManifest.Metadata(),
                    listOf(AudiobookManifest.Track(href = "a.mp3", duration = 1.0), AudiobookManifest.Track(href = "b.mp3", duration = 1.0)),
                ),
                fixture.uuid,
            )
            val app = listenOffline(fixture, scope, progress = 0.5, within = 0.5)

            assertEquals(fixture.uuid, app.listeningBook?.uuid)
            assertFalse(app.listeningWritesPositions)
            app.flushOpenReaders()
            assertTrue("written: ${positionWrites(fixture)}", positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** No manifest kept and a place that only a one-track book produces: written under the stored name. */
    @Test
    fun aSingleTrackStoredPlaceIsWrittenUnderTheServersTrackName() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.5)

            assertTrue(app.listeningWritesPositions)
            assertEquals("server-name.mp3", app.listening?.manifest?.playableTracks?.single()?.href)
            app.flushOpenReaders()
            val writes = positionWrites(fixture)
            assertTrue("nothing was written", writes.isNotEmpty())
            assertTrue(writes.all { it.body.contains("server-name.mp3") && !it.body.contains(fixture.file.name) })
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A stored place whose two progressions differ is from a longer book: no name is borrowed and nothing is written. */
    @Test
    fun aPlaceThatCouldBeFromAMultiTrackBookWritesNothing() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.6, within = 0.2)

            assertEquals(fixture.uuid, app.listeningBook?.uuid)
            assertFalse(app.listeningWritesPositions)
            app.flushOpenReaders()
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** With no stored position there is no name to borrow either. */
    @Test
    fun noStoredPlaceWritesNothingUnderTheFilesName() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope)
            assertFalse(app.listeningWritesPositions)
            app.flushOpenReaders()
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** The measured length is kept beside the file, and not trusted once the file has changed. */
    @Test
    fun theMeasuredLengthIsKeptWhileTheFileIsTheSame() {
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            assertNull(BookContentService.savedMeasuredLength(fixture.uuid))
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            assertEquals(2.0, BookContentService.savedMeasuredLength(fixture.uuid)!!, 0.0)
            assertFalse(fixture.uuid + " read as a download of its own", fixture.uuid !in BookContentService.downloadedBookUuids())
            fixture.file.writeBytes(wave() + ByteArray(8))
            assertNull(BookContentService.savedMeasuredLength(fixture.uuid))
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            BookContentService.removeDownload(fixture.uuid, BookContentService.Format.AUDIOBOOK)
            assertNull(BookContentService.savedMeasuredLength(fixture.uuid))
        } finally {
            fixture.clean()
        }
    }

    /** One book's failing answer does not block the next one's manifest; a lost connection ends the pass. */
    @Test
    fun theBackfillGoesOnPastAnAnsweredFailureAndStopsOnATransportOne() = mainTest {
        val scope = testScope()
        val first = Fixture()
        val second = Fixture()
        val third = Fixture()
        val server = StubServer { request ->
            when {
                request.path.contains(first.uuid) -> Answer(500, "{}")
                request.path.contains(second.uuid) -> Answer.json(
                    mapOf(
                        "metadata" to mapOf("title" to mapOf("und" to "Two")),
                        "readingOrder" to listOf(mapOf("href" to "two.mp3", "duration" to 2.0)),
                    ),
                )
                else -> Answer.lostConnection
            }
        }
        try {
            for (fixture in listOf(first, second, third)) fixture.file.writeBytes(wave())
            val app = testApp(scope)
            app.session = server.session()
            app.serverAddress = server.url.toString()
            app.books = listOf(first, second, third).map { SharedFixtures.book("B", uuid = it.uuid, audiobook = true) }

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertNull(BookContentService.savedManifest(first.uuid))
            assertNotNull("the book after the failing one was skipped", BookContentService.savedManifest(second.uuid))
            val asked = server.requests().map { r -> listOf(first, second, third).indexOfFirst { r.path.contains(it.uuid) } }
            assertEquals(listOf(0, 1, 2), asked)

            // Asked once per generation: a second pass asks only about the book that never answered.
            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            val again = server.requests().map { r -> listOf(first, second, third).indexOfFirst { r.path.contains(it.uuid) } }
            assertEquals(listOf(0, 1, 2, 2), again)
        } finally {
            server.close()
            first.clean(); second.clean(); third.clean()
            scope.close()
        }
    }
}
