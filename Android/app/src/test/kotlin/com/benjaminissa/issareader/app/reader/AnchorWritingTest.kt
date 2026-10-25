package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.Silence
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.time.Duration.Companion.milliseconds

/**
 * The anchor is the more durable half of a position, and it has the same
 * rule. Ported from `AnchorWritingTests.swift`.
 */
class AnchorWritingTest : AppSuite() {
    private val uuid = "anchor-writing-uuid"
    private val chapterTwo = "OEBPS/ch02.xhtml"

    private class Narrating(val model: ReaderModel, val directory: File, val server: StubServer) {
        fun tearDown() {
            directory.deleteRecursively()
            server.close()
        }
    }

    private fun model(scope: CoroutineScope, server: StubServer) =
        ReaderModel(SharedFixtures.book("Fixture", uuid = uuid), server.session(), testServices(scope))

    /** A reader with a sentence of the fixture's narration prepared, so the read-along's anchor names a real file. */
    private suspend fun narrating(scope: CoroutineScope, playing: Boolean = false): Narrating {
        val server = StubServer { Answer(404) }
        val model = model(scope, server)
        model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = 0)
        val directory = temporaryDirectory("issa-anchor-writing")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "anchor-writing", directory)
        model.attachNarration(timeline, files)
        val entry = checkNotNull(timeline.firstEntryInDocument(chapterTwo))
        assertTrue("the fixture's narration has to be reachable", model.resumeNarration(entry, playing))
        return Narrating(model, directory, server)
    }

    /** A refused reading position does not leave its anchor behind. */
    @Test
    fun aRefusedPositionWritesNoAnchor() = mainTest {
        val scope = testScope()
        val narrating = narrating(scope)
        try {
            val anchors = ArrayList<AudioAnchor>()
            narrating.model.recordAudioAnchor = { anchors.add(it) }
            narrating.model.enqueuePosition = { _, _, _ -> false }

            narrating.model.saveProgress()

            assertEquals("a place the guard refused must not be stored anyway", 0, anchors.size)
        } finally {
            narrating.tearDown()
            scope.close()
        }
    }

    /** An accepted reading position still writes its anchor. */
    @Test
    fun anAcceptedPositionWritesItsAnchor() = mainTest {
        val scope = testScope()
        val narrating = narrating(scope)
        try {
            val anchors = ArrayList<AudioAnchor>()
            narrating.model.recordAudioAnchor = { anchors.add(it) }
            narrating.model.enqueuePosition = { _, _, _ -> true }

            narrating.model.saveProgress()

            assertEquals(1, anchors.size)
            assertFalse("and it names the file it narrated", anchors.last().audioHref.isEmpty())
        } finally {
            narrating.tearDown()
            scope.close()
        }
    }

    /** F02#1: a paused voice off the page being saved leaves the anchor alone. */
    @Test
    fun aPausedVoiceOffThePageWritesNoAnchor() = mainTest {
        val scope = testScope()
        val narrating = narrating(scope)
        try {
            val model = narrating.model
            assertEquals("the voice has to be paused", false, model.readalong?.player?.isPlaying)
            val anchors = ArrayList<AudioAnchor>()
            var lastPosition: ReadiumLocator? = null
            model.recordAudioAnchor = { anchors.add(it) }
            model.enqueuePosition = { locator, _, _ ->
                lastPosition = locator
                true
            }

            model.go(toChapter = 0)
            model.saveProgress()

            assertEquals("the reader's page was saved", "OEBPS/ch01.xhtml", lastPosition?.href)
            assertEquals("and the paused sentence in chapter two was not stamped beside it", 0, anchors.size)
        } finally {
            narrating.tearDown()
            scope.close()
        }
    }

    /** A playing voice still writes its anchor from a page it is not on. */
    @Test
    fun aPlayingVoiceOffThePageStillWritesItsAnchor() = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        val model = model(scope, server)
        val directory = temporaryDirectory("issa-anchor-writing")
        try {
            model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
            val epubPackage = checkNotNull(model.epubPackage)
            val timeline = SmilParser.timeline(epubPackage)
            model.resize(PageSize(340.0, 560.0))
            model.go(toChapter = 0)
            val files = AudioExtraction.extractAudio(epubPackage, timeline, "anchor-writing", directory)
            model.attachNarration(timeline, files)
            val entry = checkNotNull(timeline.firstEntryInDocument(chapterTwo))
            val anchors = ArrayList<AudioAnchor>()
            model.recordAudioAnchor = { anchors.add(it) }
            model.enqueuePosition = { _, _, _ -> true }

            assertTrue(model.resumeNarration(entry, playing = true))
            model.go(toChapter = 0)
            assertEquals("the voice has to be talking", true, model.readalong?.player?.isPlaying)
            model.saveProgress()

            assertEquals(1, anchors.size)
            assertEquals("the sentence being spoken, not the page", entry.audioHref, anchors.last().audioHref)
        } finally {
            model.readalong?.player?.pause()
            directory.deleteRecursively()
            server.close()
            scope.close()
        }
    }
}

/**
 * What a cancelled listening writer must not still do. Ported from
 * `ListeningWriterCancellationTests` in `AnchorWritingTests.swift`.
 */
class ListeningWriterCancellationTest : AppSuite() {
    private val uuid = "listening-writer-uuid"

    /** Three tracks of a thousand seconds, over a file of silence. */
    private fun coordinator(scope: CoroutineScope): AudiobookCoordinator {
        val subject = AudiobookCoordinator(
            manifest = AudiobookManifest(
                metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book")),
                readingOrder = (0 until 3).map { AudiobookManifest.Track(href = "t$it.wav", type = "audio/wav", duration = 1_000.0) },
            ),
            source = AudiobookCoordinator.Source.Local(Silence.file),
            player = AudioPlayer(ScriptedBackend()),
            scope = scope,
        )
        // The periodic observer would walk the arrangement back between the scrub and the assertion.
        subject.player.onTimeUpdate = null
        return subject
    }

    /** A book somewhere worth writing about, with a scrub the listener made. */
    private suspend fun armed(app: AppModel, scope: CoroutineScope): Pair<Book, AudiobookCoordinator> {
        val book = SharedFixtures.book("A Book", uuid = uuid, progress = 0.4, audiobook = true)
        app.books = listOf(book)
        val coordinator = coordinator(scope)
        coordinator.seekToBookTime(1_500.0)
        coordinator.skip(30.0)
        app.installListening(coordinator, book)
        return book to coordinator
    }

    /** A writer cancelled while it sleeps spends nothing when it wakes. */
    @Test
    fun aCancelledTickSpendsNothing() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val (book, coordinator) = armed(app, scope)

        app.watchListeningProgress(book, coordinator, intervalMillis = 200)
        assertTrue("a writer has to be armed to be cancelled", app.isWritingListeningPosition)

        // Inside the sleep, not before it.
        delay(50.milliseconds)
        app.stopListening(null)
        delay(500.milliseconds)

        assertFalse(app.isWritingListeningPosition)
        assertTrue("a cancelled tick must not spend the listener's scrub", coordinator.consumeSteering())
        scope.close()
    }

    /** A writer left alone still does its work. */
    @Test
    fun anUncancelledTickStillRuns() = mainTest {
        val scope = testScope()
        val app = testApp(scope)
        val (book, coordinator) = armed(app, scope)
        try {
            app.watchListeningProgress(book, coordinator, intervalMillis = 100)
            delay(500.milliseconds)

            assertFalse("the tick read the scrub and spent it", coordinator.consumeSteering())
        } finally {
            app.stopListening(null)
            scope.close()
        }
    }
}
