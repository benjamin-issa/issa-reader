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
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.CoverReference
import com.benjaminissa.issareader.core.model.ServerGeneration
import com.benjaminissa.issareader.core.networking.Endpoint
import com.benjaminissa.issareader.core.sync.LibraryService
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.SleepTimer
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID
import kotlin.time.Duration.Companion.seconds

/**
 * A sleep timer set at bedtime, and the engine changing hands underneath it.
 * Ported from `NowPlayingAttachTests.swift`.
 */
class NowPlayingAttachTest : AppSuite() {
    companion object {
        /** An engine with nothing behind it: what is under test is which coordinator the timer is wired to. */
        fun engine(scope: CoroutineScope, title: String = "Dracula", backend: ScriptedBackend = ScriptedBackend()): AudiobookCoordinator =
            AudiobookCoordinator(
                manifest = AudiobookManifest(
                    metadata = AudiobookManifest.Metadata(title = mapOf("und" to title)),
                    readingOrder = listOf(AudiobookManifest.Track(href = "track1.mp3", type = "audio/mpeg", duration = 3_600.0)),
                ),
                source = AudiobookCoordinator.Source.Files(emptyMap()),
                player = AudioPlayer(backend),
                scope = scope,
            )

        fun book(title: String = "Dracula", uuid: String = "now-playing-uuid"): Book = SharedFixtures.book(title, uuid = uuid)
    }

    /** A duration timer carries its remaining time to the new engine. */
    @Test
    fun aDurationTimerCarriesOver() = mainTest {
        val scope = testScope()
        val fortyFiveMinutes = 45.0 * 60
        val controller = NowPlayingController(scope)
        val book = book()
        controller.attach(engine(scope), book)
        val armed = checkNotNull(controller.sleepTimer)
        armed.start(SleepTimer.Mode.Duration(fortyFiveMinutes))
        assertEquals("the setup has to have armed something", fortyFiveMinutes, armed.remaining)

        controller.attach(engine(scope), book)

        assertEquals("the hand-off silently disarmed a timer the listener had set", SleepTimer.Mode.Duration(fortyFiveMinutes), controller.sleepTimer?.mode)
        assertEquals(fortyFiveMinutes, controller.sleepTimer?.remaining)
        assertNotSame("a new engine gets a timer of its own", armed, controller.sleepTimer)
        scope.close()
    }

    /** An end-of-chapter timer carried over stops the engine that took the book. */
    @Test
    fun anEndOfChapterTimerStopsTheNewEngine() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val book = book()
        controller.attach(engine(scope), book)
        checkNotNull(controller.sleepTimer).start(SleepTimer.Mode.EndOfChapter)

        val reader = engine(scope)
        controller.attach(reader, book)
        assertEquals(SleepTimer.Mode.EndOfChapter, controller.sleepTimer?.mode)

        reader.player.play()
        assertTrue("there has to be something to stop", reader.player.isPlaying)
        reader.onChapterChangeObserved?.invoke()

        assertFalse("the book read itself aloud all night", reader.player.isPlaying)
        assertEquals("and an expiry resets, as any expiry does", SleepTimer.Mode.Off, controller.sleepTimer?.mode)
        scope.close()
    }

    /** A different book does not inherit the last one's timer. */
    @Test
    fun aDifferentBookStartsUnarmed() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        controller.attach(engine(scope), book())
        checkNotNull(controller.sleepTimer).start(SleepTimer.Mode.Duration(10.0 * 60))

        controller.attach(engine(scope, "Frankenstein"), book("Frankenstein", uuid = "another-book-uuid"))

        assertEquals(SleepTimer.Mode.Off, controller.sleepTimer?.mode)
        assertNull(controller.sleepTimer?.remaining)
        scope.close()
    }

    /** Re-attaching the same engine for the same book changes nothing. */
    @Test
    fun reAttachingTheSamePairIsANoOp() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val engine = engine(scope)
        controller.attach(engine, book())
        val timer = checkNotNull(controller.sleepTimer)
        timer.start(SleepTimer.Mode.Duration(15.0 * 60))

        // The same book value re-decoded, as a position write produces one.
        controller.attach(engine, book())

        assertSame("the same pair is the same attachment", timer, controller.sleepTimer)
        assertEquals(SleepTimer.Mode.Duration(15.0 * 60), controller.sleepTimer?.mode)
        scope.close()
    }

    /** The outgoing engine gets its volume back. */
    @Test
    fun theOutgoingEngineIsNotLeftFaded() = mainTest {
        val scope = testScope()
        val controller = NowPlayingController(scope)
        val book = book()
        val car = engine(scope)
        controller.attach(car, book)
        checkNotNull(controller.sleepTimer).start(SleepTimer.Mode.Duration(60.0))
        // Where the fade had reached when the book changed hands.
        car.player.volume = 0.2f

        controller.attach(engine(scope), book)

        assertEquals("the engine that handed the book over was left faded", 1f, car.player.volume)
        scope.close()
    }
}

/**
 * Covers for a book held from before the refresh. Ported from
 * `HeldBookCoverTests.swift`: end to end through the widget, on a session
 * detection has identified as 3.x, so these fail if the server's generation
 * ever decides the route again.
 */
class HeldBookCoverTest : AppSuite() {
    private val uuidArt = "art by uuid"
    private val hashArt = "art by hash"

    /** A 3.x server with one image behind each cover route. */
    private fun coverServer() = StubServer { request ->
        val path = request.path
        when {
            path == Endpoint.user -> Answer(200, """{"id":"reader"}""")
            path == Endpoint.V3.serverPublic -> Answer(200, """{"id":"server","capabilities":[]}""")
            path == Endpoint.V3.serverDetails -> Answer(200, """{"version":"3.0.0-beta.40"}""")
            path.startsWith(Endpoint.V3.image("")) -> Answer(200, hashArt)
            path.endsWith("/cover") -> Answer(200, uuidArt)
            else -> Answer(404)
        }
    }

    /** A row as 1.2.0 cached it from a 3.x server, or as a 2.x server sends it: every edition, no cover keys. */
    private fun unnamed(uuid: String): Book = SharedFixtures.book("Dracula", uuid = uuid, readaloud = true, audiobook = true)

    private fun namingEbookArt(sha256: String, uuid: String): Book {
        val book = unnamed(uuid)
        return book.copy(ebook = book.ebook?.copy(cover = CoverReference(sha256)))
    }

    /** A session the probe has identified as 3.x. */
    private suspend fun v3Session(server: StubServer): Session {
        val session = Session(server.url, TestTokens(), server.http)
        session.adopt("a-token")
        assertTrue(
            "the probe never identified the server",
            waitUntil(10.seconds) { session.capabilities.value.generation == ServerGeneration.V3 },
        )
        return session
    }

    /** The widget fetches a held book's art by uuid on a 3.x server. */
    @Test
    fun widgetFetchesAHeldBookByUuid() = mainTest {
        coverServer().use { server ->
            val uuid = UUID.randomUUID().toString().lowercase()
            val session = v3Session(server)
            val book = unnamed(uuid)
            val covers = CoverCache(temporaryDirectory("covers"))

            val fetched = covers.widgetCover(book, session, LibraryService.CoverShape.SQUARE)

            assertEquals(uuidArt, fetched?.data?.decodeToString())
            assertEquals(true, fetched?.isSquare)
            assertEquals(listOf(Endpoint.cover(uuid)), server.requests().map { it.path }.filter { it.contains(uuid) })
        }
    }

    /** A book that names its art is fetched by hash, and nothing by uuid. */
    @Test
    fun widgetFetchesANamedCoverByHash() = mainTest {
        coverServer().use { server ->
            val uuid = UUID.randomUUID().toString().lowercase()
            val sha256 = (UUID.randomUUID().toString() + UUID.randomUUID().toString()).replace("-", "").lowercase()
            val session = v3Session(server)
            val book = namingEbookArt(sha256, uuid)
            val covers = CoverCache(temporaryDirectory("covers"))

            val fetched = covers.widgetCover(book, session, LibraryService.CoverShape.SQUARE)

            assertEquals(hashArt, fetched?.data?.decodeToString())
            assertEquals(false, fetched?.isSquare)
            assertTrue(server.requests().none { it.path.contains(uuid) })
            assertEquals(listOf(Endpoint.V3.image(sha256)), server.requests().map { it.path }.filter { it.contains(sha256) })
        }
    }
}
