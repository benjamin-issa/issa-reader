package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.SilentAudio
import com.benjaminissa.issareader.app.Silence
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.FirstArrivalHold
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.IssaJson
import com.benjaminissa.issareader.core.diagnostics.IssaLog
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.store.LibraryStore
import com.benjaminissa.issareader.core.sync.MutationDrain
import com.benjaminissa.issareader.core.sync.MutationQueue
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.CommandMap
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.playback.PlaybackAction
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID
import kotlin.math.abs
import kotlin.time.Duration.Companion.milliseconds

/**
 * A read-along nobody has started, and one the reader has stopped.
 *
 * The coordinator exists from the moment a book opens and holds nothing, so
 * the player sheet opened on one drew the start of the book — a thumb at zero
 * and a whole book remaining — for a reader in the middle of it. The model now
 * says where Play would begin (`pendingNarrationStart`), and "Stop narration"
 * (`clearNarration`) is how a book that has been listened to gets back to
 * the state where that is the right thing to show. Ported from
 * `NarrationStopTests.swift`.
 */
class NarrationStopTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)
    private val chapterOne = "OEBPS/ch01.xhtml"
    private val chapterTwo = "OEBPS/ch02.xhtml"

    private fun run(body: suspend (CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        try {
            body(scope)
        } finally {
            scope.close()
        }
    }

    private class Opened(val model: ReaderModel, val directory: File, val server: StubServer) {
        fun tearDown() {
            model.readalong?.player?.pause()
            directory.deleteRecursively()
            server.close()
        }
    }

    private fun model(scope: CoroutineScope, server: StubServer, title: String, uuid: String, backend: () -> MediaBackend = { ScriptedBackend() }): ReaderModel {
        val model = ReaderModel(SharedFixtures.book(title, uuid = uuid), server.session(), testServices(scope, backend))
        model.enqueuePosition = { _, _, _ -> true }
        return model
    }

    /**
     * The read-along fixture open at a chapter with its narration hooked up
     * exactly as production hooks it, and the player's clock taken away: the
     * periodic observer would otherwise write the audio's own clock over the
     * numbers a test is comparing, a few thousandths off the move's.
     *
     * @param takingTheClock whether to take it, which is nearly always; a test
     *   that wants to drive a tick itself leaves it on the player.
     */
    private suspend fun opened(
        scope: CoroutineScope,
        atChapter: Int = 0,
        takingTheClock: Boolean = true,
        backend: () -> MediaBackend = { ScriptedBackend() },
    ): Opened {
        val server = StubServer { Answer(404) }
        val model = model(scope, server, "Fixture", "narration-stop-uuid", backend)
        model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        model.resize(pageSize)
        model.go(toChapter = atChapter)
        val directory = temporaryDirectory("issa-narration-stop")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "narration-stop", directory)
        model.attachNarration(timeline, files)
        if (takingTheClock) {
            val readalong = checkNotNull(model.readalong)
            readalong.player.onTimeUpdate = null
            readalong.player.onFinishedFile = null
        }
        return Opened(model, directory, server)
    }

    // Where Play would begin

    /**
     * The point of the whole property: what the sheet draws before Play is
     * what the coordinator publishes after it, so the thumb does not move when
     * Play is pressed. Chapter two, because chapter one's first sentence is
     * the start of the book and a sheet that still drew the start of the book
     * would agree with it.
     */
    @Test
    fun pendingIsWhatPlayPublishes() = run { scope ->
        for (chapter in listOf(0, 1)) {
            val fixture = opened(scope, atChapter = chapter)
            try {
                val model = fixture.model
                val readalong = checkNotNull(model.readalong)
                val pending = checkNotNull(model.pendingNarrationStart) { "a read-along nobody has started" }
                assertTrue("the guard accepts a start on the reader's own page", pending.playable)
                if (chapter > 0) assertTrue("the sheet drew the start of the book", pending.bookProgress > 0)

                model.startNarration()
                readalong.player.pause()

                assertNotNull("narration has to have started for this to mean anything", readalong.activeEntry)
                assertTrue(
                    "chapter $chapter: ${pending.bookProgress} drawn, ${readalong.bookProgress} published",
                    abs(pending.bookProgress - readalong.bookProgress) < 1e-9,
                )
                val published = checkNotNull(readalong.chapterSpan)
                val drawn = checkNotNull(pending.chapterSpan) { "and the bar is scoped to the chapter, as it will be" }
                assertTrue(abs(drawn.start - published.start) < 1e-9)
                assertTrue(abs(drawn.duration - published.duration) < 1e-9)
            } finally {
                fixture.tearDown()
            }
        }
    }

    /** It is the sentence Play would start at, whichever the page turns to. */
    @Test
    fun pendingFollowsThePage() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val first = checkNotNull(model.pendingNarrationStart)
            assertEquals(chapterOne, model.narrationStart()?.first?.textHref)

            model.go(toChapter = 1)

            val second = checkNotNull(model.pendingNarrationStart)
            assertEquals(chapterTwo, model.narrationStart()?.first?.textHref)
            assertTrue("the memo of the page before was believed", second.bookProgress > first.bookProgress)
            assertTrue(second.chapterSpan?.start != first.chapterSpan?.start)
        } finally {
            fixture.tearDown()
        }
    }

    /** It is nil once a sentence is active, and for a book with no narration. */
    @Test
    fun pendingIsNilOtherwise() = run { scope ->
        val fixture = opened(scope, atChapter = 1)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            assertNotNull(model.pendingNarrationStart)

            val start = checkNotNull(model.narrationStart())
            assertTrue(model.resumeNarration(start.first, playing = false))

            assertNotNull(readalong.activeEntry)
            assertNull("the coordinator's numbers are the truth now", model.pendingNarrationStart)

            val plain = model(scope, fixture.server, "Plain", "narration-stop-plain")
            assertNull(plain.readalong)
            assertNull(plain.pendingNarrationStart)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * A reader on a page with no narration, the nearest of it a long way on.
     * Play refuses, but the narration is there, and the sheet draws where —
     * on the audio's clock, which is the only one its bar has — with Play
     * marked as not going there.
     */
    @Test
    fun pendingIsTheDistantNarrationWhenTheStartIsTooFar() = run { scope ->
        val fixture = farFromTheNarration(scope)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val start = checkNotNull(model.narrationStart()) { "a start has to exist for the guard to refuse it" }
            assertNull("and the guard has to refuse it", model.narrationStartIfNear())
            assertTrue("the reader's own place is a different number", model.bookProgress > 0)

            val pending = checkNotNull(model.pendingNarrationStart)

            val readout = readalong.readout(start.first)
            assertEquals(start.first, pending.entry)
            assertEquals(
                "the reader's spine progress was drawn on the audio's bar",
                readout.bookProgress, pending.bookProgress, 0.0,
            )
            assertTrue(pending.bookProgress != model.bookProgress)
            val span = checkNotNull(readout.chapterSpan)
            val drawn = checkNotNull(pending.chapterSpan) { "the narration's own chapter is known" }
            assertEquals(span.start, drawn.start, 0.0)
            assertEquals(span.duration, drawn.duration, 0.0)
            assertFalse(pending.playable)

            // The same refusal Play makes, from the same function.
            model.startNarration()
            assertNull(readalong.activeEntry)
            assertFalse(readalong.player.isPlaying)
            assertNull("a refusal to start from far away is not a damaged file", model.chapterNotice)
            assertNotNull(model.pendingNarrationStart)
        } finally {
            fixture.tearDown()
        }
    }

    /** With no narration ahead of the reader there is nothing to draw. */
    @Test
    fun pendingIsNilWithNothingAhead() = run { scope ->
        val fixture = pastTheNarration(scope)
        try {
            val model = fixture.model
            assertNull("narration never starts behind the reader", model.narrationStart())

            assertNull(model.pendingNarrationStart)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * The player sheet's Play there. With no start ahead the sheet once fell
     * through to the coordinator's own play, which pressed play on a player
     * with no file in it and drew Pause over silence. It goes through the
     * reader's transport now, and so does the lock screen's play, which
     * reaches the coordinator directly.
     */
    @Test
    fun playPastTheNarrationPlaysNothing() = run { scope ->
        val fixture = pastTheNarration(scope)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            assertNull(model.pendingNarrationStart)

            model.togglePlayback()
            readalong.perform(PlaybackAction.PLAY_PAUSE, CommandMap())

            assertNull(readalong.activeEntry)
            assertFalse("Play drew Pause over a player with nothing in it", readalong.player.isPlaying)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * Drawing the sheet is not pressing Play. The refusals `narrationStartIfNear`
     * logs are for a Play that did nothing, and the diagnostics a reader exports
     * must not carry ones that never happened. A title of its own, since the log
     * is shared by every test in the process.
     */
    @Test
    fun pendingLogsNoRefusals() = run { scope ->
        val title = "Quiet-${UUID.randomUUID()}"
        val far = farFromTheNarration(scope, title)
        val past = pastTheNarration(scope, title)
        try {
            fun refusals(): List<String> = IssaLog.export().lines().filter {
                it.contains("book=$title") && it.contains("narration ") &&
                    (it.contains("too far away") || it.contains("nowhere to start"))
            }

            far.model.pendingNarrationStart
            past.model.pendingNarrationStart
            // Past the memo, which would hide a log made on the second ask.
            far.model.go(toChapter = 0)
            far.model.go(toChapter = 1)
            far.model.pendingNarrationStart

            assertTrue("the sheet logged a refusal nobody asked for: ${refusals()}", refusals().isEmpty())

            // The positive control: the same state, through Play.
            far.model.startNarration()
            past.model.startNarration()
            assertEquals("Play's refusals went unlogged: ${refusals()}", 2, refusals().size)
        } finally {
            far.tearDown()
            past.tearDown()
        }
    }

    /**
     * The reader is in chapter two, past a short plain opening, with the long
     * plain chapter between them and the only narrated one: most of the book
     * by weight, so the narration is far beyond `NARRATION_PROXIMITY_LIMIT`.
     * Chapter two and not one, so the reader's place is not the zero a
     * fallback that forgot to look would also answer.
     */
    private suspend fun farFromTheNarration(scope: CoroutineScope, title: String = "Far"): Opened {
        val filler = "<p>Filler that carries no narration at all, only weight.</p>".repeat(600)
        return book(
            scope,
            listOf(
                TestEpub.Chapter("one", "One", "<p>A short plain opening.</p>"),
                TestEpub.Chapter("two", "Two", "<p>A short plain chapter.</p>"),
                TestEpub.Chapter("three", "Three", filler),
                TestEpub.Chapter(
                    "four", "Four",
                    "<p><span id=\"s0\">The only narrated sentence in the whole book.</span></p>",
                    narrated = listOf("s0"),
                ),
            ),
            readingChapter = 1, title = title,
        )
    }

    /**
     * A long plain chapter and then a short narrated one, the reader in the
     * narrated one. By weight the reader is nearly at the end; by the audio
     * the voice is at the very start. The sheet draws the audio's clock.
     */
    @Test
    fun pendingIsAudioTimeNotReadingTime() = run { scope ->
        val filler = "<p>Filler that carries no narration at all, only weight.</p>".repeat(600)
        val fixture = book(
            scope,
            listOf(
                TestEpub.Chapter("one", "One", filler),
                TestEpub.Chapter(
                    "two", "Two",
                    "<p><span id=\"s0\">The first narrated sentence.</span> " +
                        "<span id=\"s1\">The second narrated sentence.</span></p>",
                    narrated = listOf("s0", "s1"),
                ),
            ),
            readingChapter = 1,
        )
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            assertTrue("the clocks have to disagree for this to mean anything", model.bookProgress > 0.5)
            val pending = checkNotNull(model.pendingNarrationStart)

            model.startNarration()
            readalong.player.pause()

            assertNotNull(readalong.activeEntry)
            assertTrue(abs(pending.bookProgress - readalong.bookProgress) < 1e-9)
            assertTrue(pending.bookProgress < 0.5)
        } finally {
            fixture.tearDown()
        }
    }

    /** Narration in the first chapter only, and the reader in the second. */
    private suspend fun pastTheNarration(scope: CoroutineScope, title: String = "Far"): Opened = book(
        scope,
        listOf(
            TestEpub.Chapter(
                "one", "One",
                "<p><span id=\"s0\">The only narrated sentence in the whole book.</span></p>",
                narrated = listOf("s0"),
            ),
            TestEpub.Chapter("two", "Two", "<p>A plain chapter after it.</p>"),
        ),
        readingChapter = 1, title = title,
    )

    /**
     * A book built in the test, open at a chapter with its narration hooked
     * up and the player's clock taken away, as [opened] does for the fixture.
     */
    private suspend fun book(
        scope: CoroutineScope,
        chapters: List<TestEpub.Chapter>,
        readingChapter: Int,
        title: String = "Far",
    ): Opened {
        val server = StubServer { Answer(404) }
        val model = model(scope, server, title, "narration-stop-far")
        model.epubPackage = TestEpub.epubPackage(chapters = chapters, audio = SilentAudio.wav(30))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        model.resize(pageSize)
        model.go(toChapter = readingChapter)
        val directory = temporaryDirectory("issa-narration-stop-far")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "narration-stop-far", directory)
        model.attachNarration(timeline, files)
        val readalong = checkNotNull(model.readalong)
        readalong.player.onTimeUpdate = null
        readalong.player.onFinishedFile = null
        return Opened(model, directory, server)
    }

    // Cueing from the sheet

    /**
     * The sheet's slider before narration has started. The coordinator moving
     * from no sentence announces no chapter change, so the voice went to
     * chapter two and the page stayed on chapter one.
     */
    @Test
    fun cuingTurnsThePage() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val target = checkNotNull(timeline.exactEntryForFragment("ch02-s1", chapterTwo))
            assertEquals(0, model.chapterIndex)
            assertNotNull(model.pendingNarrationStart)

            model.cueNarration((target.cumulativeEnd - target.duration) / timeline.totalDuration)

            assertEquals("the voice is in chapter two", chapterTwo, readalong.activeEntry?.textHref)
            assertEquals("and the page did not follow it", 1, model.chapterIndex)
            assertFalse(readalong.player.isPlaying)
            assertNull("the coordinator's numbers are the truth now", model.pendingNarrationStart)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * A cue inside the chapter on screen has nothing to load, and leaves the
     * reader where they are unless the follow setting moves the page.
     */
    @Test
    fun cuingWithinTheChapter() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val target = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))

            model.cueNarration((target.cumulativeEnd - target.duration) / timeline.totalDuration)

            assertEquals(target, readalong.activeEntry)
            assertEquals(0, model.chapterIndex)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * Skip, from the sheet: the start's time on the book clock plus the
     * interval, through the same cue. Back across the chapter boundary the
     * page has to turn back with it.
     */
    @Test
    fun skippingFromThePendingStart() = run { scope ->
        val fixture = opened(scope, atChapter = 1)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val total = timeline.totalDuration
            val pending = checkNotNull(model.pendingNarrationStart)
            val began = pending.entry.cumulativeEnd - pending.entry.duration
            assertTrue("chapter two has to begin far enough in for a skip back to leave it", began > 2)

            // Back a second: into the last sentences of chapter one.
            model.cueNarration(pending.progress(skippingBy = -1.0, inBookOf = total))
            assertTrue(abs(readalong.bookProgress * total - (began - 1)) < 1e-6)
            assertEquals(chapterOne, readalong.activeEntry?.textHref)
            assertEquals("the page stayed on the chapter the voice left", 0, model.chapterIndex)

            // And from a fresh start, forward.
            model.clearNarration()
            model.go(toChapter = 1)
            val again = checkNotNull(model.pendingNarrationStart)
            val forward = again.progress(skippingBy = 1.0, inBookOf = total)
            assertTrue(abs(forward * total - (began + 1)) < 1e-6)
            model.cueNarration(forward)
            assertTrue(abs(readalong.bookProgress * total - (began + 1)) < 1e-6)
            assertEquals(1, model.chapterIndex)
        } finally {
            fixture.tearDown()
        }
    }

    /** What a save handed over, kept out of the closures so the assertions read values rather than captured variables. */
    private class SaveCapture {
        var positions = 0
            private set
        var anchors = 0
            private set
        var lastLocator: ReadiumLocator? = null
            private set
        var lastOrigin: PositionOrigin? = null
            private set

        fun record(locator: ReadiumLocator, origin: PositionOrigin) {
            positions += 1
            lastLocator = locator
            lastOrigin = origin
        }

        fun record(@Suppress("UNUSED_PARAMETER") anchor: AudioAnchor) {
            anchors += 1
        }
    }

    /**
     * The scrubber or a skip back into the chapter before. `onSeek` marked
     * the position CHOSEN when the seek landed, and following the voice into
     * that chapter relabelled it DERIVED, as for a chapter the voice had
     * crossed into. A move back past the position guard's tolerance was then
     * refused on save, and the place the reader scrubbed away from stayed.
     */
    @Test
    fun aCueBackAcrossChaptersIsChosen() = run { scope ->
        val fixture = opened(scope, atChapter = 1)
        try {
            val model = fixture.model
            val saves = SaveCapture()
            model.enqueuePosition = { locator, _, origin ->
                saves.record(locator, origin)
                true
            }
            val readalong = checkNotNull(model.readalong)
            val total = checkNotNull(model.timeline).totalDuration
            val pending = checkNotNull(model.pendingNarrationStart)

            model.cueNarration(pending.progress(skippingBy = -1.0, inBookOf = total))
            assertEquals(chapterOne, readalong.activeEntry?.textHref)
            assertEquals("the page has to have followed the voice back", 0, model.chapterIndex)
            model.cancelPendingSave()
            model.saveProgress()

            assertEquals("the scrub back was saved as a move nobody made", PositionOrigin.CHOSEN, saves.lastOrigin)
        } finally {
            fixture.tearDown()
        }
    }

    /** The control: a cue that loads nothing was already the reader's choice, and still is. */
    @Test
    fun aCueWithinTheChapterIsChosen() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val saves = SaveCapture()
            model.enqueuePosition = { locator, _, origin ->
                saves.record(locator, origin)
                true
            }
            val timeline = checkNotNull(model.timeline)
            val target = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))

            model.cueNarration((target.cumulativeEnd - target.duration) / timeline.totalDuration)
            assertEquals(0, model.chapterIndex)
            model.cancelPendingSave()
            model.saveProgress()

            assertEquals(PositionOrigin.CHOSEN, saves.lastOrigin)
        } finally {
            fixture.tearDown()
        }
    }

    // Stopping the audiobook engine

    private val listeningUuid = "55555555-5555-4555-8555-555555555555"

    private class Listening(
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

    private fun silentCoordinator(scope: CoroutineScope, directory: File, takingTheClock: Boolean = false): AudiobookCoordinator {
        val coordinator = AudiobookCoordinator(
            manifest = AudiobookManifest(
                metadata = AudiobookManifest.Metadata(title = mapOf("und" to "A Book")),
                readingOrder = (0 until 3).map { AudiobookManifest.Track(href = "t$it.mp3", type = "audio/mpeg", duration = 1_000.0) },
            ),
            // A source nothing can open: the clock is what drives these.
            source = AudiobookCoordinator.Source.Local(File(directory, "missing.mp3")),
            player = AudioPlayer(ScriptedBackend()),
            scope = scope,
        )
        if (takingTheClock) coordinator.player.onTimeUpdate = null
        return coordinator
    }

    /**
     * Three tracks of a thousand seconds, half a track in, with the writer
     * armed on an interval this test never reaches, so every write seen here
     * is the stop's.
     */
    private fun listening(): Listening {
        val scope = testScope()
        val app = testApp(scope)
        val directory = temporaryDirectory("narration-stop-listening")
        val store = LibraryStore("narration-stop-listening", directory)
        app.useStore(store)
        val book = SharedFixtures.book("A Book", uuid = listeningUuid, audiobook = true)
        app.books = listOf(book)
        app.rebuildDerived()
        val coordinator = silentCoordinator(scope, directory, takingTheClock = false)
        app.installListening(coordinator, book, BookContentService.Format.AUDIOBOOK)
        app.watchListeningProgress(book, coordinator, intervalMillis = 3_600_000)
        // Half a track of listening since the writer was armed.
        coordinator.player.onTimeUpdate?.invoke(500.0)
        return Listening(app, store, directory, book, coordinator, scope, listeningUuid)
    }

    /**
     * The reader's Stop on a book the audiobook engine holds. `stopListening`
     * cancels the writer without writing, so the listening since its last tick
     * went with it.
     */
    @Test
    fun stoppingTheAudiobookWritesItsPosition() = mainTest {
        val fixture = listening()
        try {
            val progress = fixture.coordinator.bookProgress
            assertTrue("the clock has to have moved for there to be anything to lose", progress > 0.1)

            fixture.app.stopListeningWritingPosition(listeningUuid, nowPlaying = null)

            val written = fixture.queuedPositions()
            assertEquals("the listening since the writer's last tick was lost", 1, written.size)
            val total = checkNotNull(written.first().locator.totalProgression)
            assertTrue(abs(total - progress) < 0.0001)
            assertNull("and the engine is stopped", fixture.app.listeningBook)
            assertNull(fixture.app.listening)
        } finally {
            fixture.tearDown()
        }
    }

    /** A stop for another book leaves the engine and writes nothing. */
    @Test
    fun stoppingAnotherBookDoesNothing() = mainTest {
        val fixture = listening()
        try {
            fixture.app.stopListeningWritingPosition("another-book", nowPlaying = null)

            assertEquals(listeningUuid, fixture.app.listeningBook?.uuid)
            assertTrue(fixture.queuedPositions().isEmpty())
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * The write suspends for as long as the network takes. Switching to
     * another book and back meanwhile puts a new coordinator in the slot
     * under the same uuid, and the old Stop checked only the uuid: it
     * cancelled the new engine's writer, paused it and took it off the
     * screen.
     */
    @Test
    fun aHeldStopLeavesAReplacementAlone() = mainTest {
        val fixture = listening()
        try {
            val app = fixture.app
            val hold = FirstArrivalHold()
            app.beforeWritingListeningPosition = { hold.arrive() }

            val stopping = async { app.stopListeningWritingPosition(listeningUuid, nowPlaying = null) }
            assertTrue("the stop has to be held on its write", waitUntil { hold.arrivals == 1 })
            app.stopListening(null)
            val replacement = silentCoordinator(fixture.scope, fixture.directory, takingTheClock = true)
            app.installListening(replacement, fixture.book, BookContentService.Format.AUDIOBOOK)
            app.watchListeningProgress(fixture.book, replacement, intervalMillis = 3_600_000)
            hold.release()
            stopping.await()

            assertTrue("the old stop took the new engine out of the slot", app.listening === replacement)
            assertTrue("and cancelled its writer", app.isWritingListeningPosition)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * Stop pauses first, so a coordinator playing again once the write is
     * done was played by the reader after they pressed Stop.
     */
    @Test
    fun aHeldStopLeavesALaterPlayAlone() = mainTest {
        val fixture = listening()
        try {
            val app = fixture.app
            val hold = FirstArrivalHold()
            app.beforeWritingListeningPosition = { hold.arrive() }

            val stopping = async { app.stopListeningWritingPosition(listeningUuid, nowPlaying = null) }
            assertTrue("the stop has to be held on its write", waitUntil { hold.arrivals == 1 })
            assertFalse("Stop pauses before it writes", fixture.coordinator.player.isPlaying)
            fixture.coordinator.player.play()
            assertTrue(fixture.coordinator.player.isPlaying)
            hold.release()
            stopping.await()

            assertTrue("the reader's later Play was stopped", app.listening === fixture.coordinator)
            assertTrue(app.isWritingListeningPosition)
        } finally {
            fixture.tearDown()
        }
    }

    // The app's two entry points for the reader's own buttons

    /**
     * Stop Narration on a book the audiobook engine holds stops that engine,
     * writing where it was first, and puts the reader's own narration back.
     */
    @Test
    fun stopNarrationForThisBookStopsTheEngineAndWritesFirst() = mainTest {
        val fixture = listening()
        val server = StubServer { Answer(404) }
        try {
            val progress = fixture.coordinator.bookProgress
            val reader = model(fixture.scope, server, "A Book", listeningUuid)

            fixture.app.stopNarrationForThisBook(reader)

            val written = fixture.queuedPositions()
            assertEquals(1, written.size)
            assertTrue(abs(checkNotNull(written.first().locator.totalProgression) - progress) < 0.0001)
            assertNull(fixture.app.listening)
            assertFalse(fixture.coordinator.player.isPlaying)
        } finally {
            server.close()
            fixture.tearDown()
        }
    }

    /**
     * The reader's play button, on a book the audiobook engine holds, plays
     * and pauses that engine rather than a narration the book may also have.
     */
    @Test
    fun togglePlaybackForThisBookDrivesTheEngineThatHoldsTheBook() = mainTest {
        val fixture = listening()
        val server = StubServer { Answer(404) }
        try {
            val reader = model(fixture.scope, server, "A Book", listeningUuid)
            val other = model(fixture.scope, server, "Another", "another-book")
            assertFalse(fixture.coordinator.player.isPlaying)

            fixture.app.togglePlaybackForThisBook(reader)
            assertTrue("the engine was not played", fixture.coordinator.player.isPlaying)

            // Another book's reader is not the engine's to drive.
            fixture.app.togglePlaybackForThisBook(other)
            assertTrue(fixture.coordinator.player.isPlaying)

            fixture.app.togglePlaybackForThisBook(reader)
            assertFalse("the engine was not paused", fixture.coordinator.player.isPlaying)
        } finally {
            server.close()
            fixture.tearDown()
        }
    }

    // Stopping

    @Test
    fun clearingReturnsToJustOpened() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val later = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))
            assertTrue(model.resumeNarration(later, playing = true))
            readalong.player.pause()
            assertTrue(model.hasNarrationMarker)
            assertEquals("the sentence is lit on the page", "ch01-s3", model.activeFragmentId)
            assertNull(model.pendingNarrationStart)

            model.clearNarration()

            assertNull("the highlight is gone", model.activeFragmentId)
            assertNull(readalong.activeEntry)
            assertNull(readalong.activeFragmentId)
            assertEquals(0.0, readalong.bookProgress, 0.0)
            assertFalse(readalong.player.isPlaying)
            assertNull("and nothing is loaded for a tick to read", readalong.player.currentAudioHref)
            assertFalse(model.hasNarrationMarker)
            val start = checkNotNull(model.narrationStart())
            assertEquals("from what the reader can see, not from where the voice stopped", "page", start.second)
            assertTrue(start.first != later)
            assertNotNull(model.pendingNarrationStart)

            model.startNarration()
            readalong.player.pause()
            assertEquals("Play starts where the sheet said it would", start.first, readalong.activeEntry)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * The sentence outranks the page when it is on the page, and it is what a
     * book quit mid-narration comes back to. Stopping has to take that rung
     * away too, or the first Play after a stop starts exactly where it did
     * before.
     */
    @Test
    fun clearingForgetsTheQuitPoint() = run { scope ->
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("readalong"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val app = testApp(scope)
            val model = app.reader(book, local.library)
            model.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            val timeline = checkNotNull(model.timeline)
            val quitPoint = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))
            assertTrue(model.resumeNarration(quitPoint, playing = false))
            model.saveProgress()

            val relaunched = local.relaunched()
            relaunched.load()
            val again = checkNotNull(relaunched.books.firstOrNull())
            val nextApp = testApp(scope)
            val reopened = nextApp.reader(again, relaunched)
            reopened.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, reopened.phase)
            assertEquals(0, reopened.chapterIndex)
            assertEquals("reopened where the voice was", "quitPoint", reopened.narrationStart()?.second)

            reopened.clearNarration()

            val start = checkNotNull(reopened.narrationStart())
            assertEquals("page", start.second)
            assertTrue(start.first.fragmentId != "ch01-s3")
            model.readalong?.player?.pause()
            reopened.readalong?.player?.pause()
        } finally {
            local.tearDown()
        }
    }

    /**
     * The reader's place and the stored anchor are what a stop must not move.
     * Judged by what the next save writes, and by whether one was scheduled
     * at all: a stop that saved would write the page the reader is on under
     * some label, which the position guard is entitled to refuse.
     */
    @Test
    fun clearingMovesNeitherPositionNorAnchor() = run { scope ->
        val fixture = opened(scope, atChapter = 0)
        try {
            val model = fixture.model
            val saves = SaveCapture()
            model.enqueuePosition = { locator, _, origin ->
                saves.record(locator, origin)
                true
            }
            model.recordAudioAnchor = { saves.record(it) }
            val timeline = checkNotNull(model.timeline)
            val later = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))
            assertTrue(model.resumeNarration(later, playing = false))
            model.saveProgress()
            assertTrue("the baseline: a position and its anchor", saves.positions == 1 && saves.anchors == 1)
            val before = checkNotNull(saves.lastLocator)
            val origin = checkNotNull(saves.lastOrigin)
            // Nothing waiting from the setup, so anything waiting afterwards is the
            // stop's.
            model.cancelPendingSave()

            model.clearNarration()
            // Past the two seconds the debounce waits.
            delay(2400.milliseconds)
            assertEquals("a save was scheduled", 1, saves.positions)

            model.saveProgress()
            assertEquals(2, saves.positions)
            assertEquals("and the voice is no longer anywhere to anchor", 1, saves.anchors)
            assertEquals("the position's classification was disturbed", origin, saves.lastOrigin)
            val after = checkNotNull(saves.lastLocator)
            assertEquals(before.href, after.href)
            assertEquals(before.locations?.charOffset, after.locations?.charOffset)
            assertEquals(before.locations?.totalProgression, after.locations?.totalProgression)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * The reason the file is unloaded as well as the sentence forgotten: the
     * player's observer fires on a pause, and a coordinator that only forgot
     * had the sentence — and the highlight, and a save — back at the next tick.
     */
    @Test
    fun aTickAfterStoppingDoesNotResurrect() = run { scope ->
        val fixture = opened(scope, atChapter = 0, takingTheClock = false)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            // Taken here instead, so that the one tick below is the only one.
            val tick = checkNotNull(readalong.player.onTimeUpdate)
            readalong.player.onTimeUpdate = null
            readalong.player.onFinishedFile = null
            val timeline = checkNotNull(model.timeline)
            val later = checkNotNull(timeline.exactEntryForFragment("ch01-s3", chapterOne))
            assertTrue(model.resumeNarration(later, playing = false))
            assertEquals("ch01-s3", model.activeFragmentId)

            model.clearNarration()
            tick(later.start + 0.01)

            assertNull(readalong.activeEntry)
            assertNull("the sentence was lit again", model.activeFragmentId)
        } finally {
            fixture.tearDown()
        }
    }

    /**
     * A start that has not finished opening its file when the reader stops.
     * The play must not land afterwards: not as sound, not as a lit sentence,
     * and not as a notice that the file would not play.
     */
    @Test
    fun aStopDuringAStartDoesNotPlay() = run { scope ->
        // The stop lands while the file is being asked for its length: the
        // scripted engine's counterpart of the player's `whileLoadingAsset`.
        var onLoading: (() -> Unit)? = null
        val backend = ScriptedBackend(
            durationOf = { location ->
                onLoading?.let { hook ->
                    onLoading = null
                    hook()
                }
                if (location is AudioLocation.LocalFile && !location.file.isFile) null else Silence.DURATION
            },
        )
        val fixture = opened(scope, atChapter = 1, backend = { backend })
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            onLoading = { model.clearNarration() }

            model.startNarration()

            assertFalse("it played after the stop", readalong.player.isPlaying)
            assertNull(readalong.activeEntry)
            assertNull(model.activeFragmentId)
            assertNull(readalong.player.currentAudioHref)
            assertNull("the stop was reported as a file that would not play", model.chapterNotice)
            assertNotNull("and the book is as it was just opened", model.pendingNarrationStart)

            // And a start after the stop is a start.
            model.startNarration()
            readalong.player.pause()
            assertNotNull(readalong.activeEntry)
        } finally {
            fixture.tearDown()
        }
    }
}
