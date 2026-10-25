package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.PlaybackSettingsForTests
import com.benjaminissa.issareader.app.ScriptedBackend
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.Silence
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.app.model.AppModel
import com.benjaminissa.issareader.app.model.NowPlayingController
import com.benjaminissa.issareader.app.model.PlaybackSettings
import com.benjaminissa.issareader.core.Session
import com.benjaminissa.issareader.core.download.BookContentService
import com.benjaminissa.issareader.core.model.AudiobookManifest
import com.benjaminissa.issareader.core.model.Book
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilEntry
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.epub.SmilTimeline
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.AudioLocation
import com.benjaminissa.issareader.playback.AudioPlayer
import com.benjaminissa.issareader.playback.AudiobookChapter
import com.benjaminissa.issareader.playback.AudiobookCoordinator
import com.benjaminissa.issareader.playback.ChunkManifest
import com.benjaminissa.issareader.playback.ControlSurface
import com.benjaminissa.issareader.playback.ListeningHandoff
import com.benjaminissa.issareader.playback.ListeningResume
import com.benjaminissa.issareader.playback.MediaBackend
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.yield
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * The fixture the hand-off suites share: the read-along book opened on
 * chapter one with its narration extracted, and a car engine over the very
 * same chunks. Ported from the static helpers of
 * `ListeningHandoffReaderTests.swift`, which `DepartedReaderTests` borrows too.
 */
object HandoffFixture {
    const val UUID = "readalong-fixture-uuid"
    const val CHAPTER_TWO = "OEBPS/ch02.xhtml"

    /** The extracted narration, and the directory holding it. */
    class Opened(val files: Map<String, File>, val directory: File)

    /** A manifest over the fixture's own chunks, in the shape `startListening` hands to `attachListening`. */
    class Chunked(
        val manifest: AudiobookManifest,
        val chapters: List<AudiobookChapter>,
        val files: Map<String, File>,
        val timeline: SmilTimeline,
    )

    /** A reader open over a parked car engine, and what to tidy up. */
    class Armed(val model: ReaderModel, val coordinator: AudiobookCoordinator, val book: Book, val directory: File)

    /**
     * The fixture's narration on disk, as `prepareNarration` would leave it:
     * through `AudioExtraction` rather than a hand-made map, because a
     * coordinator handed files that do not exist refuses to move — which would
     * make every assertion pass for the wrong reason.
     */
    fun extracted(epubPackage: EpubPackage, timeline: SmilTimeline): Opened {
        val directory = temporaryDirectory("issa-handoff-reader")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "handoff-reader", directory)
        return Opened(files, directory)
    }

    /**
     * A reader open on chapter one of the fixture, with its narration hooked
     * up — the state a phone is in when the car is unplugged. The car engine
     * is built over the very same chunks: that is what makes an anchor written
     * by one engine mean something to the other.
     */
    suspend fun opened(model: ReaderModel): Opened {
        model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = 0)
        val extraction = extracted(epubPackage, timeline)
        model.attachNarration(timeline, extraction.files)
        return extraction
    }

    fun secondChapterOpening(model: ReaderModel): SmilEntry =
        checkNotNull(checkNotNull(model.timeline).firstEntryInDocument(CHAPTER_TWO))

    fun chunked(model: ReaderModel, files: Map<String, File>): Chunked {
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        val built = ChunkManifest.make(timeline, epubPackage, files, durations = emptyMap(), title = "Fixture")
        return Chunked(built.manifest, built.chapters, built.files, timeline)
    }

    /** A car engine over the fixture's own chunks, parked one second into the second track — the second chapter. */
    suspend fun parked(model: ReaderModel, files: Map<String, File>, scope: CoroutineScope): AudiobookCoordinator {
        val built = chunked(model, files)
        val coordinator = AudiobookCoordinator(
            built.manifest, AudiobookCoordinator.Source.Files(built.files), player = AudioPlayer(ScriptedBackend()), scope = scope,
        )
        // The periodic observer would walk the seek back between the
        // arrangement and the assertion.
        coordinator.player.onTimeUpdate = null
        val firstTrack = checkNotNull(built.manifest.playableTracks.first().duration)
        coordinator.seekToBookTime(firstTrack + 1)
        return coordinator
    }

    /**
     * The same engine, playing from the top — where a start nobody could
     * resolve begins. Loaded, not merely constructed: chunk one at offset zero
     * is a real anchor the overlay places on chapter one's first sentence.
     */
    suspend fun startedFromZero(model: ReaderModel, files: Map<String, File>, scope: CoroutineScope): AudiobookCoordinator {
        val built = chunked(model, files)
        val coordinator = AudiobookCoordinator(
            built.manifest, AudiobookCoordinator.Source.Files(built.files), player = AudioPlayer(ScriptedBackend()), scope = scope,
        )
        coordinator.player.onTimeUpdate = null
        coordinator.start(0.0)
        return coordinator
    }

    /** Settings of its own, so a rate or a level another suite persisted cannot change the coordinator. */
    fun settings(): PlaybackSettings = PlaybackSettingsForTests.make()

    /**
     * A reader visible before the car engine is installed, so nothing is
     * scheduled behind the explicit call and the decision it returns is the
     * one under test.
     */
    suspend fun armed(app: AppModel, session: Session, scope: CoroutineScope): Armed {
        val book = SharedFixtures.book("Fixture", uuid = UUID, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, session)
        val opened = opened(model)
        app.setForeground(true)
        app.setReaderVisible(UUID, true)
        val coordinator = parked(model, opened.files, scope)
        return Armed(model, coordinator, book, opened.directory)
    }

    val ListeningHandoff.Decision.handedOver: Boolean get() = this is ListeningHandoff.Decision.HandOff

    val ListeningHandoff.Decision.target: ListeningHandoff.Target? get() = (this as? ListeningHandoff.Decision.HandOff)?.target

    fun skipped(skip: ListeningHandoff.Skip): ListeningHandoff.Decision = ListeningHandoff.Decision.Skipped(skip)
}

/**
 * The end of a drive. Ported from `ListeningHandoffReaderTests.swift`.
 *
 * `AudiobookCoordinator` is what Android Auto, the lock screen and the Listen
 * button start; for a downloaded read-along it plays the EPUB's own narration
 * chunks, so it knows exactly where it is and the page knows nothing at all.
 * `ListeningHandoff` decides; this is what the reader and the app do about it.
 */
class ListeningHandoffReaderTest : AppSuite() {
    private val uuid = HandoffFixture.UUID

    /** The origin a save was written under. */
    private class OriginCapture {
        var last: PositionOrigin? = null
    }

    /** A one-shot latch: the hand-off pauses the car engine twice on the branch that uses it. */
    private class Gate {
        private var open = true
        fun close(): Boolean {
            val was = open
            open = false
            return was
        }
    }

    private class Harness(val app: AppModel, val scope: CoroutineScope, val server: StubServer) {
        val session: Session = server.session()
        val directories = ArrayList<File>()

        suspend fun armed(): HandoffFixture.Armed = HandoffFixture.armed(app, session, scope).also { directories.add(it.directory) }

        fun tearDown() {
            directories.forEach { it.deleteRecursively() }
            server.close()
            scope.close()
        }
    }

    private fun run(makeBackend: () -> MediaBackend = { ScriptedBackend() }, body: suspend (Harness) -> Unit) = mainTest {
        val scope = testScope()
        val harness = Harness(testApp(scope, makeBackend = makeBackend), scope, StubServer { Answer(404) })
        try {
            body(harness)
        } finally {
            harness.tearDown()
        }
    }

    private suspend fun settle(condition: () -> Boolean) {
        waitUntil { condition() }
    }

    // The reader's half

    /** The playing case: the voice carries on out of the phone, and the page catches up with it. */
    @Test
    fun resumeNarrationAtASentencePlaysItAndTurnsThePage() = run { harness ->
        val model = ReaderModel(SharedFixtures.book("Fixture", uuid = uuid), harness.session, harness.app.readerServices!!)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val entry = HandoffFixture.secondChapterOpening(model)
        // Chained rather than replaced, so the model's own handler still runs.
        var seeks = 0
        val readalong = checkNotNull(model.readalong)
        val announce = readalong.onSeek
        readalong.onSeek = {
            seeks += 1
            announce?.invoke()
        }

        val took = model.resumeNarration(entry, playing = true)

        assertTrue(took)
        assertEquals(entry, model.readalong?.activeEntry)
        assertEquals("the page has to follow the voice", 1, model.chapterIndex)
        assertEquals(true, model.readalong?.player?.isPlaying)
        assertEquals("an audio clock named this place, not the reader", 0, seeks)

        // The label the position is saved under: a place the reader chose
        // disarms the high-water guard on the place they actually reached.
        val origin = OriginCapture()
        model.enqueuePosition = { _, _, seen ->
            origin.last = seen
            true
        }
        model.saveProgress()
        assertEquals(PositionOrigin.DERIVED, origin.last)
        model.readalong?.player?.pause()
    }

    /** The parked-and-paused case. The page still moves; the room stays quiet. */
    @Test
    fun resumeNarrationCanLandWithoutPlaying() = run { harness ->
        val model = ReaderModel(SharedFixtures.book("Fixture", uuid = uuid), harness.session, harness.app.readerServices!!)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val entry = HandoffFixture.secondChapterOpening(model)

        val took = model.resumeNarration(entry, playing = false)

        assertTrue(took)
        assertEquals(1, model.chapterIndex)
        assertEquals("nobody asked for audio", false, model.readalong?.player?.isPlaying)

        val origin = OriginCapture()
        model.enqueuePosition = { _, _, seen ->
            origin.last = seen
            true
        }
        model.saveProgress()
        assertEquals(PositionOrigin.DERIVED, origin.last)
    }

    // The app's half

    /** A car still playing hands the book to the reader that came back. */
    @Test
    fun theReaderTakesOverFromAPlayingCar() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        armed.coordinator.player.play()
        app.installListening(armed.coordinator, armed.book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.READER_VISIBLE)

        with(HandoffFixture) { assertTrue(decision.handedOver) }
        assertNull("two engines on one book is two voices in the room", app.listening)
        assertEquals("the voice has to carry on", true, armed.model.readalong?.player?.isPlaying)
        assertEquals(1, armed.model.chapterIndex)
        assertFalse(armed.coordinator.player.isPlaying)
        armed.model.readalong?.player?.pause()
    }

    /** The call site, not just the method: a reader appearing over a playing car hands the book over on its own. */
    @Test
    fun theCallSiteReachesTheHandOff() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        armed.coordinator.player.play()
        app.installListening(armed.coordinator, armed.book)
        // Off and on again: the reader leaving and coming back.
        app.setReaderVisible(uuid, false)

        app.setReaderVisible(uuid, true)

        settle { app.listening == null }
        assertNull("nothing reached the hand-off", app.listening)
        assertEquals(1, armed.model.chapterIndex)
        armed.model.readalong?.player?.pause()
    }

    /**
     * The rung that exists for a person. A phone in a pocket reports a
     * visible reader and a foreground app for the whole drive, and taking the
     * book off the dashboard at 70mph is the one outcome nobody can recover from.
     */
    @Test
    fun theCarKeepsPlaybackWhileConnected() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        armed.coordinator.player.play()
        app.setControlSurface(ControlSurface.CAR)
        app.installListening(armed.coordinator, armed.book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.READER_VISIBLE)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.CAR_CONNECTED), decision)
        assertSame("the car must keep the book", armed.coordinator, app.listening)
        assertTrue("and must keep playing it", armed.coordinator.player.isPlaying)
        armed.coordinator.player.pause()
    }

    /** Nothing is handed over while the app is in the background: a visible reader alone would fire this from a pocket. */
    @Test
    fun nothingHappensInTheBackground() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        armed.coordinator.player.play()
        app.setForeground(false)
        app.installListening(armed.coordinator, armed.book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.FOREGROUND)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.BACKGROUND), decision)
        assertSame(armed.coordinator, app.listening)
        assertTrue(armed.coordinator.player.isPlaying)
        armed.coordinator.player.pause()
    }

    /**
     * Parked, paused, and walked inside. The page has to be the one they
     * stopped on; the room has to stay quiet — and the paused car engine must
     * still be taken off the footer, the mini bar and the lock screen.
     */
    @Test
    fun aPausedCarEngineMovesThePageAndStaysSilent() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        val model = armed.model
        app.installListening(armed.coordinator, armed.book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED)

        with(HandoffFixture) {
            assertTrue(decision.handedOver)
            assertEquals(false, decision.target?.wasPlaying)
        }
        assertNull("a paused engine still owns Now Playing until it is stopped", app.listening)
        assertEquals("nobody asked for audio", false, model.readalong?.player?.isPlaying)
        assertEquals(HandoffFixture.CHAPTER_TWO, model.readalong?.activeEntry?.textHref)
        assertEquals(1, model.chapterIndex)
        // The half the paused path used to drop on the floor: something has
        // to own the transport, or there is no mini bar, no player sheet and
        // a car whose chapter list has gone empty.
        assertEquals("something has to own the transport", uuid, app.playbackBook?.uuid)
        assertSame("and the car reads its chapters off this", model, app.reader)
    }

    /**
     * The other paused case: the hand-off is refused, and the book stays with
     * the engine that still knows where it is — with its writer re-armed, or
     * everything from that pause onwards is written nowhere.
     */
    @Test
    fun aFailedPausedHandOffKeepsTheWriter() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        val model = armed.model
        // The reader's narration, pointed at no files at all: the half-deleted
        // extraction this failure path exists for.
        val timeline = checkNotNull(model.timeline)
        model.attachNarration(timeline, emptyMap())
        app.installListening(armed.coordinator, armed.book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.AUDIO_FILE_MISSING), decision)
        assertSame("the engine keeps a book nothing else can place", armed.coordinator, app.listening)
        assertEquals("and Now Playing is still its own", uuid, app.listeningBook?.uuid)
        assertFalse("a paused car stays paused", armed.coordinator.player.isPlaying)
        assertTrue("an hour from here would be written nowhere", app.isWritingListeningPosition)
        app.stopListening(null)
    }

    /**
     * The 2026-09-09 loss, reached through the other clock. A book playing
     * from a place nobody resolved keeps the reader where it is: handing it
     * over would save the front of the book, text-scaled, over a part-read novel.
     */
    @Test
    fun anUnresolvedStartIsNotHandedToTheReader() = run { harness ->
        val app = harness.app
        // The server's own single upload, on the audio clock: a file this
        // book's chunks have never heard of.
        val book = SharedFixtures.book(
            "Fixture", uuid = uuid, progress = 0.62,
            positionHref = "the-whole-book.mp3", positionType = "audio/mpeg", readaloud = true,
        )
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        app.setForeground(true)
        app.setReaderVisible(uuid, true)
        // What `attachListening` does when the ladder resolves nothing.
        app.prepareListeningGuard(book, trusted = false)
        val coordinator = HandoffFixture.startedFromZero(model, opened.files, harness.scope)
        app.installListening(coordinator, book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.READER_VISIBLE)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.RESUME_UNRESOLVED), decision)
        assertNull("nothing may have moved the page", model.readalong?.activeEntry)
        assertEquals("the reader keeps the chapter it had", 0, model.chapterIndex)
        assertSame("and the car plays on from where it started", coordinator, app.listening)
        assertEquals("with the stored place untouched", 0.62, app.books.first().progress)
        app.stopListening(null)
    }

    // The two states the hand-off used to wait on for nothing

    /**
     * The listener presses Listen from the book they have open: a start
     * finishing over an open reader hands the book straight over.
     */
    @Test
    fun aStartOverAnOpenReaderHandsItOver() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        app.setForeground(true)
        app.setReaderVisible(uuid, true)
        val built = HandoffFixture.chunked(model, opened.files)

        val outcome = app.attachListening(
            built.manifest, AudiobookCoordinator.Source.Files(built.files),
            built.chapters, built.timeline, ListeningResume.ManifestKind.SYNTHESISED, book,
            NowPlayingController(harness.scope), HandoffFixture.settings(),
        )

        assertEquals("the start has to have worked for this to mean anything", AppModel.ListeningAttachment.STARTED, outcome)
        // The hand-off runs on a task of its own, as it does from every other trigger.
        settle { app.listening == null }
        assertNull("two engines on one book is two voices in the room", app.listening)
        assertSame("the reader owns the book it is showing", model, app.reader)
        assertNotNull("and the page is following the voice", model.readalong?.activeEntry)
        model.readalong?.player?.pause()
    }

    /** The listener steering releases the hold, and the book moves: there is no other trigger left to fire. */
    @Test
    fun steeringReleasesTheHoldAndHandsTheBookOver() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book(
            "Fixture", uuid = uuid, progress = 0.62,
            positionHref = "the-whole-book.mp3", positionType = "audio/mpeg", readaloud = true,
        )
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        app.setForeground(true)
        app.setReaderVisible(uuid, true)
        app.prepareListeningGuard(book, trusted = false)
        val coordinator = HandoffFixture.startedFromZero(model, opened.files, harness.scope)
        app.installListening(coordinator, book)

        // The held state, which is where this starts and used to end.
        val held = app.handOffListeningToReader(ListeningHandoff.Trigger.READER_VISIBLE)
        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.RESUME_UNRESOLVED), held)

        // The listener scrubs: `.chosen` is the one thing that releases a held clock.
        app.admitPosition(audioScrub(0.30), PositionOrigin.CHOSEN, uuid)

        settle { app.listening == null }
        assertNull("the hold let go, so the book can move", app.listening)
        assertSame(model, app.reader)
        assertNotNull("and the page followed it", model.readalong?.activeEntry)
        model.readalong?.player?.pause()
    }

    /** A listening position on the audio clock, as a scrub writes it: `audio/mpeg` files it under the held guard. */
    private fun audioScrub(progression: Double) = ReadiumLocator(
        href = "the-whole-book.mp3", type = "audio/mpeg",
        locations = ReadiumLocator.Locations(totalProgression = progression),
    )

    // The slot changing hands underneath a hand-off

    /** A second book's engine, with nothing behind it: what is asserted is which coordinator the slot holds. */
    private fun otherEngine(scope: CoroutineScope) = AudiobookCoordinator(
        manifest = AudiobookManifest(
            metadata = AudiobookManifest.Metadata(title = mapOf("und" to "Another Book")),
            readingOrder = listOf(AudiobookManifest.Track(href = "track1.mp3", type = "audio/mpeg", duration = 60.0)),
        ),
        source = AudiobookCoordinator.Source.Files(emptyMap()),
        player = AudioPlayer(ScriptedBackend()),
        scope = scope,
    )

    /**
     * A slot taken while the read-along was loading is not handed over: the
     * hand-off used to finish the transfer for a pair the app no longer held,
     * and silence the book the listener had just started.
     */
    @Test
    fun aSlotTakenDuringTheLoadIsNotHandedOver() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        val model = armed.model
        app.installListening(armed.coordinator, armed.book)

        // Unawaited: everything under test happens while this is suspended
        // loading chapter two's audio.
        val handOff = harness.scope.async { app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED) }
        yield()
        assertSame("the hand-off has to still be in flight", armed.coordinator, app.listening)

        // The listener starts something else while the page is still loading.
        val other = otherEngine(harness.scope)
        val otherBook = SharedFixtures.book("Another Book", uuid = "another-book-uuid")
        app.installListening(other, otherBook)
        val decision = handOff.await()

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS), decision)
        assertSame("the hand-off has no claim on what took the slot", other, app.listening)
        assertEquals(otherBook.uuid, app.listeningBook?.uuid)
        assertNull("nor may it claim narration for a book that left", app.reader)
        assertEquals("and it started no second voice", false, model.readalong?.player?.isPlaying)
    }

    /**
     * A failed hand-off gives nothing back to an engine it no longer owns —
     * nor re-arms a writer over the one the new holder armed. Staged through
     * the car engine's own rate observer, which fires as the hand-off pauses it.
     */
    @Test
    fun aFailedHandOffGivesNothingBackToAStrippedEngine() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        val model = armed.model
        val coordinator = armed.coordinator
        // Narration pointed at no files at all, so `resumeNarration` refuses.
        val timeline = checkNotNull(model.timeline)
        model.attachNarration(timeline, emptyMap())
        app.installListening(coordinator, armed.book)
        // One shot: `slotChangedHands` pauses the engine again on its way out.
        val taken = Gate()
        coordinator.player.setRateObserver(taken) { _ ->
            if (!taken.close()) return@setRateObserver
            app.stopListening(null)
        }

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS), decision)
        assertNull("the hand-off must not put a stripped engine back", app.listening)
        assertFalse("nor start one playing again", coordinator.player.isPlaying)
        assertFalse(
            "the writer belongs to whatever holds the book now, and must not be cancelled",
            app.isWritingListeningPosition,
        )
    }

    /**
     * A removal landing inside a playing hand-off does not claim the book:
     * only the claim tells a removal apart from the hand-off's own transfer.
     */
    @Test
    fun aRemovalInsideAPlayingHandOffIsNotOverrun() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        val model = armed.model
        armed.coordinator.player.play()
        app.installListening(armed.coordinator, armed.book)

        val handOff = harness.scope.async { app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED) }
        yield()
        assertSame("the hand-off has to still be in flight", armed.coordinator, app.listening)

        // The reader deletes the read-along while the page is loading, through the real entry point.
        app.removeDownload(uuid, BookContentService.Format.READALOUD)
        val decision = handOff.await()

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.SLOT_CHANGED_HANDS), decision)
        assertNull("nothing may narrate a book whose text has gone", app.reader)
        assertEquals(
            "a read-along reading out of a deleted extraction is the silence this prevents",
            false, model.readalong?.player?.isPlaying,
        )
        assertNull(app.listening)
        assertFalse(app.isWritingListeningPosition)
    }

    /**
     * What the reader's own play button has to consult: a book mid-hand-off
     * says so, while its old engine is still in the slot looking exactly as it
     * did before. The button is a composable; this is the fact it asks for.
     */
    @Test
    fun aBookMidHandOffIsVisibleToTheReader() = run { harness ->
        val app = harness.app
        val armed = harness.armed()
        app.installListening(armed.coordinator, armed.book)
        assertFalse("nothing is moving yet", app.isHandingOffToReader(uuid))

        val handOff = harness.scope.async { app.handOffListeningToReader(ListeningHandoff.Trigger.CAR_DISCONNECTED) }
        yield()

        assertSame("the slot looks exactly as it did before", armed.coordinator, app.listening)
        assertFalse("and the button would offer to play it", armed.coordinator.player.isPlaying)
        assertTrue("which is the one thing that says not to", app.isHandingOffToReader(uuid))

        handOff.await()
        assertFalse("and it is over when it is over", app.isHandingOffToReader(uuid))
    }

    // Starting, while the book is being taken away

    /**
     * A start overrun by a hand-off leaves no second player behind.
     * `stopListening` stands in for the hand-off: it is exactly what the
     * hand-off does to the slot.
     */
    @Test
    fun aStartOverrunByAHandOffPlaysNothing() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val built = HandoffFixture.chunked(model, opened.files)

        // Started rather than awaited: everything under test happens while this is suspended.
        val start = harness.scope.async {
            app.attachListening(
                built.manifest, AudiobookCoordinator.Source.Files(built.files),
                built.chapters, built.timeline, ListeningResume.ManifestKind.SYNTHESISED, book,
                NowPlayingController(harness.scope), HandoffFixture.settings(),
            )
        }
        // Everything up to the first suspension runs before this resumes.
        yield()
        val orphan = checkNotNull(app.listening) { "the start has to have claimed the slot" }

        app.stopListening(null)
        val outcome = start.await()

        assertEquals(AppModel.ListeningAttachment.SLOT_TAKEN, outcome)
        assertFalse("two engines on one book is two voices", orphan.player.isPlaying)
        assertNull("the start must not put itself back", app.listening)
        assertFalse("nor leave a writer bound to a dead engine", app.isWritingListeningPosition)
    }

    // A start that makes no sound has to say so

    /**
     * A resolved resume whose audio will not load. Android Auto reads
     * `listeningError` back as its success signal, so a silent failure must
     * not look like a book that started.
     */
    @Test
    fun aDeclinedSeekSpeaksUp() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val built = HandoffFixture.chunked(model, opened.files)
        // A stored position on this manifest's own clock, so the resume ladder
        // resolves and the seek is the thing that fails.
        val track = built.manifest.playableTracks.first().href
        val resumed = SharedFixtures.book(
            "Fixture", uuid = uuid, progress = 0.01,
            positionHref = track, positionType = "audio/mpeg", readaloud = true,
        )

        val outcome = app.attachListening(
            built.manifest,
            // The manifest over an extraction that has since gone.
            AudiobookCoordinator.Source.Files(emptyMap()),
            built.chapters, built.timeline, ListeningResume.ManifestKind.SYNTHESISED, resumed,
            NowPlayingController(harness.scope), HandoffFixture.settings(),
        )

        assertEquals(AppModel.ListeningAttachment.WOULD_NOT_PLAY, outcome)
        assertNotNull("a silent failure must not read as a success", app.listeningError)
        assertNotEquals("there is nothing to play", true, app.listening?.player?.isPlaying)
        assertFalse("nor anything to write about", app.isWritingListeningPosition)
    }

    /** The same one rung down: nothing resolved, so the start is from zero, and its outcome is what has to be asked. */
    @Test
    fun anUnresolvedStartThatLoadsNothingSpeaksUp() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val built = HandoffFixture.chunked(model, opened.files)

        val outcome = app.attachListening(
            built.manifest, AudiobookCoordinator.Source.Files(emptyMap()),
            built.chapters, built.timeline, ListeningResume.ManifestKind.SYNTHESISED, book,
            NowPlayingController(harness.scope), HandoffFixture.settings(),
        )

        assertEquals(AppModel.ListeningAttachment.WOULD_NOT_PLAY, outcome)
        assertNotNull(app.listeningError)
        assertNull("nothing was ever loaded", app.listening?.player?.currentAudioHref)
        assertFalse(app.isWritingListeningPosition)
    }

    /**
     * The case the one above cannot reach: the first track is there and will
     * not open. The engine here refuses a file that is not audio, as the
     * decoder does; every chunk is present, and none of them is audio.
     */
    @Test
    fun anUnresolvedStartWhoseTrackWillNotOpenSpeaksUp() = run(makeBackend = { notAudioRefused() }) { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        val opened = HandoffFixture.opened(model)
        harness.directories.add(opened.directory)
        val built = HandoffFixture.chunked(model, opened.files)
        val broken = File(opened.directory, "not-audio").apply { mkdirs() }
        val unreadable = LinkedHashMap<String, File>()
        for (href in built.files.keys) {
            val file = File(broken, "${unreadable.size}.mp3")
            file.writeText(NOT_AUDIO)
            unreadable[href] = file
        }

        val outcome = app.attachListening(
            built.manifest, AudiobookCoordinator.Source.Files(unreadable),
            built.chapters, built.timeline, ListeningResume.ManifestKind.SYNTHESISED, book,
            NowPlayingController(harness.scope), HandoffFixture.settings(),
        )

        assertEquals("a track that would not open was reported as a start", AppModel.ListeningAttachment.WOULD_NOT_PLAY, outcome)
        assertNotNull("Android Auto reads a null error as success", app.listeningError)
        assertNotEquals(true, app.listening?.player?.isPlaying)
        assertFalse("the writer was armed over a player holding nothing", app.isWritingListeningPosition)
    }

    /** The scripted engine, refusing a file whose bytes are the sentence above rather than audio. */
    private fun notAudioRefused() = ScriptedBackend(
        durationOf = { location ->
            when (location) {
                is AudioLocation.LocalFile ->
                    if (location.file.isFile && location.file.length() != NOT_AUDIO.length.toLong()) Silence.DURATION else null
                is AudioLocation.Remote -> Silence.DURATION
            }
        },
    )

    /**
     * A cold open: the screen appears long before the narration is
     * extracted, so there is nothing to hand the book to yet. `readerReady`
     * brings the decision back when there is.
     */
    @Test
    fun aReaderWithoutNarrationIsNotReady() = run { harness ->
        val app = harness.app
        val book = SharedFixtures.book("Fixture", uuid = uuid, readaloud = true)
        app.books = listOf(book)
        val model = app.reader(book, harness.session)
        model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = 0)
        app.setReaderVisible(uuid, true)

        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        val extraction = HandoffFixture.extracted(epubPackage, timeline)
        harness.directories.add(extraction.directory)
        val built = ChunkManifest.make(timeline, epubPackage, extraction.files, durations = emptyMap(), title = "Fixture")
        val coordinator = AudiobookCoordinator(
            built.manifest, AudiobookCoordinator.Source.Files(built.files), player = AudioPlayer(ScriptedBackend()), scope = harness.scope,
        )
        coordinator.player.onTimeUpdate = null
        val firstTrack = checkNotNull(coordinator.manifest.playableTracks.first().duration)
        coordinator.seekToBookTime(firstTrack + 1)
        coordinator.player.play()
        app.installListening(coordinator, book)

        val decision = app.handOffListeningToReader(ListeningHandoff.Trigger.READER_READY)

        assertEquals(HandoffFixture.skipped(ListeningHandoff.Skip.READER_NOT_READY), decision)
        assertSame(coordinator, app.listening)
        assertTrue(coordinator.player.isPlaying)
        coordinator.player.pause()
    }

    private companion object {
        const val NOT_AUDIO = "this is not an mp3 file"
    }
}
