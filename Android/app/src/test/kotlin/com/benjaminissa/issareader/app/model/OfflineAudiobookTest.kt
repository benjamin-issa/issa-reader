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
            assertNull("nothing is kept on the device when the server has the place", BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A kept manifest that is not this file's length writes nothing to the server and keeps the place on the device. */
    @Test
    fun aKeptManifestOfAnotherLengthWritesNothingToTheServer() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(twoTracks(5.0, 5.0), fixture.uuid)
            val app = listenOffline(fixture, scope, progress = 0.25)
            // The stored place is another track list's, so the listener names one.
            app.listening!!.seekToBookTime(1.5)
            app.listening!!.skip(0.1)
            app.flushOpenReaders()

            assertTrue("written: ${positionWrites(fixture)}", positionWrites(fixture).isEmpty())
            assertEquals(1.6, BookContentService.savedStandInPlace(fixture.uuid)!!.seconds, 0.01)
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /**
     * No manifest kept: nothing goes to the server, the session is not lost: a stop and a
     * restart resume from the place kept on the device, not from the older stored one.
     */
    @Test
    fun withNoKeptManifestTheStandInResumesFromTheDevicePlace() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.25)
            app.listening!!.seekToBookTime(1.5)
            app.listening!!.skip(0.1)
            app.stopListeningWritingPosition(fixture.uuid, null)

            assertTrue("written: ${positionWrites(fixture)}", positionWrites(fixture).isEmpty())
            assertNotNull("the session was lost", BookContentService.savedStandInPlace(fixture.uuid))
            assertNull(app.listening)

            listenOffline(fixture, scope, progress = 0.25, app = app, reopen = true)

            assertEquals(0.8, app.listening!!.bookProgress, 0.01)
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** A stored position newer than the device place wins over it. */
    @Test
    fun aNewerStoredPositionWinsOverTheDevicePlace() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveStandInPlace(com.benjaminissa.issareader.core.model.StandInPlace(1.5, 1_000.0), fixture.uuid)

            val app = listenOffline(fixture, scope, progress = 0.25, storedAt = 2_000.0)

            assertEquals(0.25, app.listening!!.bookProgress, 0.01)
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    /** Once the manifest is known, the device's place is written as a normal position, once, and forgotten. */
    @Test
    fun theDevicePlaceIsWrittenWhenTheManifestIsKnown() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        val server = StubServer { request ->
            if (request.path == com.benjaminissa.issareader.core.networking.Endpoint.listen(fixture.uuid)) {
                Answer.json(
                    mapOf(
                        "metadata" to mapOf("title" to mapOf("und" to "Offline")),
                        "readingOrder" to listOf(
                            mapOf("href" to "a.mp3", "type" to "audio/mpeg", "duration" to 1.0),
                            mapOf("href" to "b.mp4", "type" to "audio/mp4", "duration" to 1.0),
                        ),
                    ),
                )
            } else {
                Answer(200, "{}")
            }
        }
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            val now = com.benjaminissa.issareader.core.sync.ProgressService.now()
            BookContentService.saveStandInPlace(com.benjaminissa.issareader.core.model.StandInPlace(1.5, now), fixture.uuid)
            val app = testApp(scope)
            val directory = com.benjaminissa.issareader.app.temporaryDirectory("offline-convert")
            app.useStore(com.benjaminissa.issareader.core.store.LibraryStore("offline-convert", directory))
            app.session = server.session()
            app.serverAddress = server.url.toString()
            app.books = listOf(SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            app.flushOpenReaders()

            val writes = server.requests().filter { it.method == "POST" && it.path.endsWith("/positions") }
            assertEquals("written: $writes", 1, writes.size)
            assertTrue(writes.single().body, writes.single().body.contains("b.mp4") && writes.single().body.contains("\"totalProgression\":0.75"))
            assertNull(BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            server.close()
            fixture.clean()
            scope.close()
        }
    }

    /** A place the manifest does not describe is kept for offline use, not written and not dropped. */
    @Test
    fun aDevicePlaceTheManifestDoesNotDescribeIsKept() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        val server = StubServer {
            Answer.json(
                mapOf(
                    "metadata" to mapOf("title" to mapOf("und" to "Offline")),
                    "readingOrder" to listOf(mapOf("href" to "a.mp3", "duration" to 90.0)),
                ),
            )
        }
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            BookContentService.saveStandInPlace(
                com.benjaminissa.issareader.core.model.StandInPlace(1.5, com.benjaminissa.issareader.core.sync.ProgressService.now()),
                fixture.uuid,
            )
            val app = testApp(scope)
            app.session = server.session()
            app.serverAddress = server.url.toString()
            app.books = listOf(SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertTrue(server.requests().none { it.method == "POST" })
            assertNotNull(BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            server.close()
            fixture.clean()
            scope.close()
        }
    }

    /**
     * A start that could not place the listener (a text position the audio cannot be
     * matched to) holds the audio clock. A place kept on the device goes through the
     * same guard: nothing is kept until the listener steers, and a steer keeps one.
     */
    @Test
    fun anUntrustedStandInKeepsNothingOnTheDeviceUntilTheListenerSteers() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            val app = listenOffline(fixture, scope, progress = 0.7, textPosition = true)
            val coordinator = app.listening!!

            coordinator.seekToBookTime(1.0)
            app.flushOpenReaders()
            assertNull("an untrusted session kept a place", BookContentService.savedStandInPlace(fixture.uuid))
            coordinator.consumeSteering()

            coordinator.skip(0.25)
            app.flushOpenReaders()

            assertEquals(1.25, BookContentService.savedStandInPlace(fixture.uuid)!!.seconds, 0.05)
            assertTrue(positionWrites(fixture).isEmpty())
        } finally {
            fixture.clean()
            scope.close()
        }
    }

    private fun twoTrackAnswer() = Answer.json(
        mapOf(
            "metadata" to mapOf("title" to mapOf("und" to "Offline")),
            "readingOrder" to listOf(
                mapOf("href" to "a.mp3", "type" to "audio/mpeg", "duration" to 1.0),
                mapOf("href" to "b.mp4", "type" to "audio/mp4", "duration" to 1.0),
            ),
        ),
    )

    /** A write the guard refused is not a write: the place stays for a start that can place it. */
    @Test
    fun aPlaceTheGuardRefusedIsKept() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        val server = StubServer { if (it.method == "GET") twoTrackAnswer() else Answer(200, "{}") }
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveMeasuredLength(2.0, fixture.uuid)
            BookContentService.saveStandInPlace(
                com.benjaminissa.issareader.core.model.StandInPlace(1.5, com.benjaminissa.issareader.core.sync.ProgressService.now()),
                fixture.uuid,
            )
            val app = testApp(scope)
            app.useStore(com.benjaminissa.issareader.core.store.LibraryStore("offline-refused", com.benjaminissa.issareader.app.temporaryDirectory("offline-refused")))
            app.session = server.session()
            app.serverAddress = server.url.toString()
            val locator = com.benjaminissa.issareader.core.model.ReadiumLocator(
                href = "chapter.xhtml", type = "application/xhtml+xml",
                locations = com.benjaminissa.issareader.core.model.ReadiumLocator.Locations(progression = 0.7, totalProgression = 0.7),
            )
            val book = SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true)
                .copy(position = com.benjaminissa.issareader.core.model.StoredPosition(locator = locator, timestamp = 1.0))
            app.books = listOf(book)
            app.prepareListeningGuard(book, trusted = false)

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)
            app.flushOpenReaders()

            assertTrue("written: ${server.requests()}", server.requests().none { it.method == "POST" })
            assertNotNull("the refused place was forgotten", BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            server.close()
            fixture.clean()
            scope.close()
        }
    }

    private fun throwingServices(scope: kotlinx.coroutines.CoroutineScope) = com.benjaminissa.issareader.app.reader.ReaderServices(
        scope = scope,
        fonts = com.benjaminissa.issareader.app.testFonts,
        makeMediaBackend = { ScriptedBackend() },
        measurer = com.benjaminissa.issareader.playback.DurationMeasurer { throw IllegalStateException("cannot measure") },
    )

    /** A conversion that throws is no reason for a refresh to crash. */
    @Test
    fun aConversionThatThrowsDoesNotEndTheBackfill() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        val server = StubServer { twoTrackAnswer() }
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveStandInPlace(
                com.benjaminissa.issareader.core.model.StandInPlace(1.5, com.benjaminissa.issareader.core.sync.ProgressService.now()),
                fixture.uuid,
            )
            val app = testApp(scope)
            app.readerServices = throwingServices(scope)
            app.session = server.session()
            app.serverAddress = server.url.toString()
            app.books = listOf(SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true))

            app.backfillAudiobookManifests(app.session!!, app.catalogueGeneration)

            assertNotNull("the manifest was not kept", BookContentService.savedManifest(fixture.uuid))
            assertNotNull("the place was lost", BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            server.close()
            fixture.clean()
            scope.close()
        }
    }

    /** ...nor for a start to fall back to the stand-in when the server did answer. */
    @Test
    fun aConversionThatThrowsDoesNotTurnAStartIntoAStandIn() = mainTest {
        val scope = testScope()
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveManifest(
                AudiobookManifest(AudiobookManifest.Metadata(), listOf(AudiobookManifest.Track(href = "one.mp3", duration = 2.0))),
                fixture.uuid,
            )
            BookContentService.saveStandInPlace(
                com.benjaminissa.issareader.core.model.StandInPlace(1.0, com.benjaminissa.issareader.core.sync.ProgressService.now()),
                fixture.uuid,
            )
            val app = testApp(scope)
            app.readerServices = throwingServices(scope)
            app.session = fixture.server.session()
            app.serverAddress = fixture.server.url.toString()
            val book = SharedFixtures.book("Offline", uuid = fixture.uuid, audiobook = true)
            app.books = listOf(book)

            app.startListening(book, NowPlayingController(scope), PlaybackSettingsForTests.make())

            assertNull("listening said: ${app.listeningError}", app.listeningError)
            assertEquals("one.mp3", app.listening?.manifest?.playableTracks?.single()?.href)
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

    /** The place goes with the download. */
    @Test
    fun theDevicePlaceGoesWithTheDownload() {
        val fixture = Fixture()
        try {
            fixture.file.writeBytes(wave())
            BookContentService.saveStandInPlace(com.benjaminissa.issareader.core.model.StandInPlace(1.0, 5.0), fixture.uuid)
            assertNotNull(BookContentService.savedStandInPlace(fixture.uuid))
            BookContentService.removeDownload(fixture.uuid, BookContentService.Format.AUDIOBOOK)
            assertNull(BookContentService.savedStandInPlace(fixture.uuid))
        } finally {
            fixture.clean()
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
