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
import kotlinx.coroutines.launch

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

    // The offline stand-in: what it writes, what it keeps on the device, and what it converts.

    private fun twoTracks(a: Double = 1.0, b: Double = 1.0) = AudiobookManifest(
        AudiobookManifest.Metadata(),
        listOf(
            AudiobookManifest.Track(href = "a.mp3", type = "audio/mpeg", duration = a),
            AudiobookManifest.Track(href = "b.mp4", type = "audio/mp4", duration = b),
        ),
    )

    private suspend fun listenOffline(
        fixture: Fixture,
        scope: kotlinx.coroutines.CoroutineScope,
        progress: Double? = null,
        storedAt: Double = 1.0,
        textPosition: Boolean = false,
        app: AppModel = testApp(scope),
        reopen: Boolean = false,
    ): AppModel {
        if (!reopen) {
            val directory = com.benjaminissa.issareader.app.temporaryDirectory("offline-standin")
            app.useStore(com.benjaminissa.issareader.core.store.LibraryStore("offline-standin", directory))
            app.session = fixture.server.session()
            app.serverAddress = fixture.server.url.toString()
        }
        var book = SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true)
        if (progress != null) {
            val locator = com.benjaminissa.issareader.core.model.ReadiumLocator(
                href = if (textPosition) "chapter.xhtml" else "b.mp4",
                type = if (textPosition) "application/xhtml+xml" else "audio/mp4",
                locations = com.benjaminissa.issareader.core.model.ReadiumLocator.Locations(
                    progression = progress, totalProgression = progress,
                ),
            )
            book = book.copy(position = com.benjaminissa.issareader.core.model.StoredPosition(locator = locator, timestamp = storedAt))
        }
        app.books = listOf(book)
        app.startListening(book, NowPlayingController(scope), PlaybackSettingsForTests.make())
        return app
    }

    private fun positionWrites(fixture: Fixture) =
        fixture.server.requests().filter { it.method == "POST" && it.path.endsWith("/positions") }

    /**
     * A kept manifest whose tracks add up to the file: the place is written under the
     * track and offset the server's manifest gives it, with the whole book's progression.
     */
    @Test
    fun aMatchingKeptMultiTrackManifestWritesTheRightTrackAndOffset() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(twoTracks(), fixture.uuid)
            // Stored in the second track, half-way in: three quarters of the way through the book.
            val app = listenOffline(fixture, scope, progress = 0.5)
            val tracks = app.listening!!.manifest.playableTracks
            assertEquals("the stand-in plays the file as one track", 1, tracks.size)
            assertEquals(fixture.file.name, tracks.single().href)

            app.listening!!.seekToBookTime(1.5)
            app.flushOpenReaders()

            val writes = positionWrites(fixture)
            assertTrue("nothing was written", writes.isNotEmpty())
            val body = writes.last().body
            assertTrue(body, body.contains("b.mp4") && body.contains("audio/mp4") && !body.contains(fixture.file.name))
            assertTrue(body, body.contains("\"progression\":0.5") && body.contains("\"totalProgression\":0.75"))
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A book that timed out earlier is asked before one that keeps timing out, because the order is the order they failed in. */
    @Test
    fun theBookThatFailedMostRecentlyGoesLast() = mainTest {
        val scope = testScope()
        val fixtures = List(2) { Fixture() }
        var bUp = false
        val server = StubServer { request ->
            when {
                request.path.contains(fixtures[0].uuid) -> Answer.lostConnection
                bUp -> manifestAnswer()
                else -> Answer.lostConnection
            }
        }
        try {
            val app = testApp(scope)
            app.session = server.session()
            app.serverAddress = server.url.toString()
            app.books = fixtures.map { SharedFixtures.book("B", uuid = it.uuid, audiobook = true) }
            // Only B is downloaded for the first pass.
            fixtures[1].file.writeBytes(wave())
            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals(listOf(1), asked(server, fixtures))
            fixtures[0].file.writeBytes(wave())
            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals("A had not failed, so it is first", listOf(1, 0), asked(server, fixtures))

            bUp = true
            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertEquals("B failed before A, so it goes first", 1, asked(server, fixtures)[2])
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }

    /** A kept manifest that no longer decodes is asked for again. */
    @Test
    fun anUndecodableKeptManifestIsRefetched() = mainTest {
        val scope = testScope()
        val fixtures = List(1) { Fixture() }
        val server = StubServer { manifestAnswer() }
        try {
            val app = backfillApp(scope, server, fixtures)
            BookContentService.manifestFile(BookContentService.defaultDirectory(), fixtures[0].uuid).writeText("not json")
            assertNull(BookContentService.savedManifest(fixtures[0].uuid))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertNotNull(BookContentService.savedManifest(fixtures[0].uuid))
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }

    /** With no file loaded a streamed session has no anchor; a mapped stand-in writes none either. */
    @Test
    fun aMappedStandInWritesNoAnchorWhileNothingIsLoaded() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(twoTracks(), fixture.uuid)
            val app = listenOffline(fixture, scope, progress = 0.5)
            app.listening!!.seekToBookTime(1.5)
            app.listening!!.player.unload()
            assertNull(app.listening!!.currentAnchor)

            app.flushOpenReaders()

            assertTrue("the position is still written", positionWrites(fixture).isNotEmpty())
            assertNull("an anchor with no file loaded", app.store!!.audioAnchor(fixture.uuid))
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A kept manifest that is not this file's length: no position and no anchor go to the server. */
    @Test
    fun aKeptManifestOfAnotherLengthWritesNothingToTheServer() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(twoTracks(5.0, 5.0), fixture.uuid)
            val app = listenOffline(fixture, scope, progress = 0.25)
            app.listening!!.seekToBookTime(1.5)
            app.listening!!.skip(0.1)
            app.flushOpenReaders()

            assertTrue("written: ${positionWrites(fixture)}", positionWrites(fixture).isEmpty())
            assertNull("an anchor with no track the server names", app.store!!.audioAnchor(fixture.uuid))
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /**
     * A session that cannot map its place does not spend the listener's steer or
     * ask the guard: a held clock stays held, so a later start is not mistaken
     * for one that placed the listener.
     */
    @Test
    fun aNonMappingSessionLeavesTheHoldAndTheSteerAlone() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.7, textPosition = true)
            val coordinator = app.listening!!
            coordinator.seekToBookTime(1.0)
            coordinator.skip(0.25)

            app.flushOpenReaders()

            assertTrue("the steer was spent on a write that did not happen", coordinator.consumeSteering())
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** Nothing is kept on the device: a stop and an offline restart resume from the stored position. */
    @Test
    fun anOfflineRestartResumesFromTheStoredPosition() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.25)
            app.listening!!.seekToBookTime(1.5)
            app.stopListeningWritingPosition(fixture.uuid, null)
            assertNull(app.listening)

            listenOffline(fixture, scope, progress = 0.25, app = app, reopen = true)

            assertEquals(0.25, app.listening!!.bookProgress, 0.01)
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A session that writes nothing to the server still keeps the widget current. */
    @Test
    fun theWidgetKeepsUpDuringASessionThatWritesNothing() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        var reloads = 0
        try {
            fixture.file.writeBytes(wave())
            val app = testApp(scope)
            app.currentBookPublisher = com.benjaminissa.issareader.app.model.CurrentBookPublisher(scope, reload = { reloads += 1 })
            listenOffline(fixture, scope, progress = 0.25, app = app)
            val book = app.listeningBook!!
            val coordinator = app.listening!!
            val before = reloads

            coordinator.seekToBookTime(1.5)
            app.watchListeningProgress(book, coordinator, intervalMillis = 50)

            assertTrue("the widget froze", com.benjaminissa.issareader.app.waitUntil { reloads > before })
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
            // The length file is not an edition: with the audio gone, nothing it leaves reads as a download.
            val audio = fixture.file.readBytes()
            fixture.file.delete()
            assertTrue("the length file is still there", BookContentService.lengthFile(BookContentService.defaultDirectory(), fixture.uuid).exists())
            assertFalse(fixture.uuid + " read as a download of its own", fixture.uuid in BookContentService.downloadedBookUuids())
            fixture.file.writeBytes(audio)
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            fixture.file.writeBytes(wave() + ByteArray(8))
            assertNull(BookContentService.savedMeasuredLength(fixture.uuid))
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            BookContentService.removeDownload(fixture.uuid, BookContentService.Format.AUDIOBOOK)
            assertNull(BookContentService.savedMeasuredLength(fixture.uuid))
        } finally {
            fixture.clean()
        }
    }

    private fun manifestAnswer() = Answer.json(
        mapOf(
            "metadata" to mapOf("title" to mapOf("und" to "Two")),
            "readingOrder" to listOf(mapOf("href" to "two.mp3", "duration" to 2.0)),
        ),
    )

    private suspend fun backfillApp(
        scope: kotlinx.coroutines.CoroutineScope,
        server: StubServer,
        fixtures: List<Fixture>,
    ): AppModel {
        for (fixture in fixtures) fixture.file.writeBytes(wave())
        val app = testApp(scope)
        app.session = server.session()
        app.serverAddress = server.url.toString()
        app.books = fixtures.map { SharedFixtures.book("B", uuid = it.uuid, audiobook = true) }
        return app
    }

    private fun asked(server: StubServer, fixtures: List<Fixture>) =
        server.requests().map { r -> fixtures.indexOfFirst { r.path.contains(it.uuid) } }

    /**
     * A book whose request never got an answer ends the pass and goes to the end of the next
     * one, so a book that always times out cannot stand in front of the others.
     */
    @Test
    fun aBookThatTimesOutMovesToTheEndOfTheNextPass() = mainTest {
        val scope = testScope()
        val fixtures = List(3) { Fixture() }
        val server = StubServer { request ->
            if (request.path.contains(fixtures[0].uuid)) Answer.lostConnection else manifestAnswer()
        }
        try {
            val app = backfillApp(scope, server, fixtures)

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals("the pass ends at the first transport failure", listOf(0), asked(server, fixtures))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals(listOf(0, 1, 2, 0), asked(server, fixtures))
            assertNotNull(BookContentService.savedManifest(fixtures[1].uuid))
            assertNotNull(BookContentService.savedManifest(fixtures[2].uuid))
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }

    /** A 503 is worth asking again; a 404 is an answer for this account generation. */
    @Test
    fun aRetryableStatusLeavesTheBookUnmarkedAndANotFoundMarksIt() = mainTest {
        val scope = testScope()
        val fixtures = List(3) { Fixture() }
        val server = StubServer { request ->
            when {
                request.path.contains(fixtures[0].uuid) -> Answer(503, "{}")
                request.path.contains(fixtures[1].uuid) -> Answer(404, "{}")
                else -> manifestAnswer()
            }
        }
        try {
            val app = backfillApp(scope, server, fixtures)

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals("a failing answer does not end the pass", listOf(0, 1, 2), asked(server, fixtures))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals("only the 503 is asked again", listOf(0, 1, 2, 0), asked(server, fixtures))
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }

    /** Not authenticated ends the pass without marking anything. */
    @Test
    fun aRefusedSessionEndsThePassAndMarksNothing() = mainTest {
        val scope = testScope()
        val fixtures = List(2) { Fixture() }
        val server = StubServer { Answer(401, "{}") }
        try {
            val app = backfillApp(scope, server, fixtures)

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertEquals(1, server.requests().count { it.path.contains(fixtures[0].uuid) || it.path.contains(fixtures[1].uuid) })
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }

    /** A second refresh while a pass is running does nothing. */
    @Test
    fun overlappingRefreshesRunOnePass() = mainTest {
        val scope = testScope()
        val fixtures = List(2) { Fixture() }
        val server = StubServer { manifestAnswer() }
        try {
            val app = backfillApp(scope, server, fixtures)
            val path = com.benjaminissa.issareader.core.networking.Endpoint.listen(fixtures[0].uuid)
            server.hold(path)

            val first = scope.launch { app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration) }
            assertTrue("the first pass never reached the server", com.benjaminissa.issareader.app.waitUntil { server.held(path) == 1 })
            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            assertEquals("a second pass asked too", 1, server.requests().size)

            server.release(path)
            first.join()
            assertEquals(listOf(0, 1), asked(server, fixtures))
        } finally {
            server.close()
            fixtures.forEach { it.clean() }
            scope.close()
        }
    }
}
