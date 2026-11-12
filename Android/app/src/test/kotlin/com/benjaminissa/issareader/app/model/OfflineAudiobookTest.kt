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
}
