package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.LocalFixtures
import com.benjaminissa.issareader.app.OpenClipBook
import com.benjaminissa.issareader.app.ReaderOpening
import com.benjaminissa.issareader.app.SilentAudio
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.jsonText
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testApp
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.app.model.FirstArrivalHold
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import com.benjaminissa.issareader.core.sync.PositionOrigin
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.playback.ChunkDurations
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * The 1.4.0 review's reader and narration findings, each against the real
 * `open(pageSize)` or the coordinator production builds. Ported from
 * `ReaderNarrationFixesTests.swift`.
 */
class ReaderNarrationFixesTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)

    private fun prose(ordinal: String) =
        "<h1>The $ordinal chapter</h1><p>This is the $ordinal chapter, and there are enough words in it to count as prose.</p>"

    private fun run(body: suspend (CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        try {
            body(scope)
        } finally {
            scope.close()
        }
    }

    // R-13: a local read-along's real file lengths

    /**
     * Two chapters, each one file, each sentence a `clipBegin` with no end:
     * the last of each file runs to the end of the file, which only the
     * file's measured length says.
     */
    private val openClipChapters = listOf(
        OpenClipBook.Chapter("ch1", "One", 3, listOf(0.0, 1.5)),
        OpenClipBook.Chapter("ch2", "Two", 5, listOf(0.0, 2.0)),
    )

    /** A local read-along whose clips state no end gets its files' real lengths, measured once. */
    @Test
    fun openClipsGetRealLengths() = run { scope ->
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick(OpenClipBook.data(openClipChapters), "open.epub"))
            val book = checkNotNull(local.library.books.firstOrNull()) { "the book was not added" }
            assertTrue("it has to be added as a read-along for this to mean anything", book.hasReadalong)
            val app = testApp(scope)
            val model = app.reader(book, local.library)

            model.open(pageSize)

            assertEquals(ReaderModel.Phase.Ready, model.phase)
            val timeline = checkNotNull(model.timeline)
            assertTrue("the book clock is ${timeline.totalDuration} s for eight seconds of narration", abs(timeline.totalDuration - 8) < 0.1)
            assertTrue("and the coordinator's with it", abs((model.readalong?.totalDuration ?: 0.0) - 8) < 0.1)
            assertTrue(timeline.filesNeedingLength.isEmpty())
            val last = checkNotNull(timeline.exactEntryForFragment("ch2-s1", "OEBPS/ch2.xhtml"))
            assertTrue("the last clip of a file runs to its end, not ${last.end}", abs(last.end - 5) < 0.1)

            // Kept beside the narration, in the book's own folder.
            val files = local.library.files(book.uuid)
            val cached = ChunkDurations.loadFromDirectory(files.narration)
            assertEquals("the lengths were not cached in Local/<uuid>/: $cached", 2, cached.size)

            // And read back rather than measured again: a cache saying
            // otherwise is believed on the next open.
            File(files.narration, "durations.json").writeText(
                jsonText(
                    mapOf(
                        OpenClipBook.audioHref(openClipChapters[0]) to 30.0,
                        OpenClipBook.audioHref(openClipChapters[1]) to 50.0,
                    ),
                ),
            )
            val nextApp = testApp(scope)
            val reopened = nextApp.reader(book, local.library)
            reopened.open(pageSize)
            assertTrue(
                "the second open measured again instead of reading the cache",
                abs((reopened.timeline?.totalDuration ?: 0.0) - 80) < 0.1,
            )
            model.readalong?.player?.pause()
            reopened.readalong?.player?.pause()
        } finally {
            local.tearDown()
        }
    }

    /**
     * The same book, before it has ever been opened: listed at its real
     * length as it is added, not at the clips' few milliseconds for each open
     * last clip.
     */
    @Test
    fun openClipsListedAtRealLength() = run { scope ->
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick(OpenClipBook.data(openClipChapters), "open.epub"))
            val book = checkNotNull(local.library.books.firstOrNull()) { "the book was not added" }
            assertTrue("it has to be added as a read-along for this to mean anything", book.hasReadalong)

            // What the row and Book info read.
            val length = checkNotNull(book.narrationDuration)
            assertTrue("listed at $length s for eight seconds of narration", abs(length - 8) < 0.1)

            // Kept where the reader's first open looks for them, and nothing
            // left over in `.incoming/`.
            val files = local.library.files(book.uuid)
            val cached = ChunkDurations.loadFromDirectory(files.narration)
            assertEquals("the measured lengths were not kept in Local/<uuid>/Audio/: $cached", 2, cached.size)
            assertTrue("left in .incoming/: ${local.incoming()}", local.incoming().isEmpty())

            // Stored with the row, so a relaunch lists it the same.
            val relaunched = local.relaunched()
            relaunched.load()
            assertTrue(abs((relaunched.books.firstOrNull()?.narrationDuration ?: 0.0) - 8) < 0.1)
        } finally {
            local.tearDown()
        }
    }

    // MAC-3: resuming where the voice was

    /**
     * A local book narrated to its fourth sentence and quit there: the place
     * saved is the page, the anchor is the sentence. Relaunched, play starts
     * at the sentence the anchor names.
     */
    @Test
    fun resumesAtTheQuitSentence() = run { scope ->
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("readalong"))
            val book = checkNotNull(local.library.books.firstOrNull())
            val app = testApp(scope)
            val model = app.reader(book, local.library)
            model.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            val timeline = checkNotNull(model.timeline)
            val quitPoint = checkNotNull(timeline.exactEntryForFragment("ch01-s3", "OEBPS/ch01.xhtml"))
            assertEquals(0, model.chapterIndex)

            // The voice on the fourth sentence of the page on screen, and the
            // quit flush: the page and the anchor.
            assertTrue(model.resumeNarration(quitPoint, playing = false))
            model.saveProgress()
            assertEquals(quitPoint.audioHref, local.library.audioAnchor(book.uuid)?.audioHref)

            // Relaunched.
            val relaunched = local.relaunched()
            relaunched.load()
            val again = checkNotNull(relaunched.books.firstOrNull())
            val nextApp = testApp(scope)
            val reopened = nextApp.reader(again, relaunched)
            reopened.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, reopened.phase)
            assertEquals("the page is the one that was saved", 0, reopened.chapterIndex)

            val start = checkNotNull(reopened.narrationStart())
            assertEquals("play would start at ${start.first.fragmentId}, not where the voice was", "ch01-s3", start.first.fragmentId)
        } finally {
            local.tearDown()
        }
    }

    /** An anchor off the page on screen does not pull narration back to it. */
    @Test
    fun anOffPageAnchorIsIgnored() = run { scope ->
        val local = LocalFixtures(scope)
        try {
            local.importAndWait(local.pick("readalong"))
            val book = checkNotNull(local.library.books.firstOrNull())
            // The voice paused in chapter one; the reader's place is chapter two.
            local.library.recordAudioAnchor(AudioAnchor(audioHref = "OEBPS/Audio/track1.mp3", offset = 15.0, writtenAt = 1.0), book.uuid)
            assertTrue(
                local.library.writePosition(
                    ReadiumLocator(
                        href = "OEBPS/ch02.xhtml", type = "application/xhtml+xml",
                        locations = ReadiumLocator.Locations(progression = 0.0, totalProgression = 0.8),
                    ),
                    10_000.0, PositionOrigin.CHOSEN, book.uuid,
                ),
            )
            val app = testApp(scope)
            val model = app.reader(book, local.library)
            model.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            assertEquals("OEBPS/ch02.xhtml", model.epubPackage?.spine?.get(model.chapterIndex)?.href)

            val start = checkNotNull(model.narrationStart())
            assertEquals("narration was pulled back to chapter one", "OEBPS/ch02.xhtml", start.first.textHref)
        } finally {
            local.tearDown()
        }
    }

    // R-10: a press over narration that would not open

    /** Narration whose file will not open says so, and does not claim to play. */
    @Test
    fun deadNarrationSaysSo() = run { scope ->
        val opening = ReaderOpening(ReaderOpening.readalongFixture())
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            model.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            val timeline = checkNotNull(model.timeline)
            val missing = File(temporaryDirectory("issa-dead-narration"), "missing.mp3")
            val dead = timeline.entries.map { it.audioHref }.toSet().associateWith { missing }
            model.attachNarration(timeline, dead)

            model.togglePlayback()

            assertFalse(model.isPlaying)
            val notice = checkNotNull(model.chapterNotice) { "nothing told the reader why nothing played" }
            assertEquals(ReaderModel.NARRATION_UNPLAYABLE, notice.message)

            model.togglePlayback()
            assertFalse("the second press played over the dead file", model.isPlaying)
        } finally {
            opening.tearDown()
        }
    }

    // R-50: an open that fell back from an unreadable landing chapter

    /** Narrated chapter one, and a chapter two that will not parse — where the stored position says the reader was. */
    private fun fallbackBook(): ByteArray = TestEpub.data(
        chapters = listOf(
            TestEpub.Chapter(
                "ch1", "Chapter One",
                "<p><span id=\"s0\">${"Spoken words go here. ".repeat(6)}</span></p>",
                narrated = listOf("s0"),
            ),
            TestEpub.Chapter("ch2", "Chapter Two", "<p>A <b>broken chapter</p>"),
        ),
        audio = SilentAudio.wav(4),
    )

    private val storedInBrokenChapter = StoredPosition(
        locator = ReadiumLocator(
            href = "OEBPS/ch2.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(progression = 0.5, totalProgression = 0.8),
        ),
        timestamp = 1_000.0,
    )

    /** A book that fell back to its first chapter is not shown as failed while its narration is prepared. */
    @Test
    fun fallbackClearsTheFailure() = run { scope ->
        val opening = ReaderOpening(fallbackBook(), position = storedInBrokenChapter)
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            var phaseWhilePreparing: ReaderModel.Phase? = null
            model.whilePreparingNarration = { phaseWhilePreparing = model.phase }

            model.open(pageSize)

            assertEquals(ReaderModel.Phase.Ready, model.phase)
            assertEquals("it fell back to the first chapter", 0, model.chapterIndex)
            val seen = checkNotNull(phaseWhilePreparing) { "narration was never prepared" }
            assertFalse(
                "the reader showed the failure screen while narration was prepared: $seen",
                seen is ReaderModel.Phase.Failed,
            )
        } finally {
            opening.tearDown()
        }
    }

    /** An open superseded by Try Again stands down rather than installing a second narration. */
    @Test
    fun aSupersededOpenStandsDown() = run { scope ->
        val opening = ReaderOpening(fallbackBook())
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            val hold = FirstArrivalHold()
            model.whilePreparingNarration = { hold.arrive() }

            val first = scope.async { model.open(pageSize) }
            assertTrue("the first open never reached its narration", waitUntil { hold.arrivals > 0 })
            model.retryOpen(pageSize)
            val second = checkNotNull(model.readalong) { "the retry did not open the book" }
            hold.release()
            first.await()

            assertSame("the superseded open installed a second coordinator", second, model.readalong)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
        } finally {
            opening.tearDown()
        }
    }

    /**
     * An open cancelled while its narration is extracted leaves the
     * extraction where a removal can still revoke it. The open's await gave
     * the cancellation up as "no narration" and let go of the slot while the
     * extraction ran on, so the removal that followed, revoking it first as
     * it must, reached nothing, and the extraction wrote on into the folder
     * being deleted.
     */
    @Test
    fun aCancelledOpenLeavesItsExtractionRevocable() = run { scope ->
        val opening = ReaderOpening(fallbackBook())
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            val extracting = CountDownLatch(1)
            val carryOn = CountDownLatch(1)
            val revoked = CompletableDeferred<Boolean>()
            model.extractNarration = { _, _, _, _, isCancelled ->
                extracting.countDown()
                carryOn.await(10, TimeUnit.SECONDS)
                revoked.complete(isCancelled())
                emptyMap()
            }

            val open = scope.async { model.open(pageSize) }
            assertTrue("the open never reached its extraction", waitUntil { extracting.count == 0L })
            // The reader closes mid-open, and the book is removed: the
            // removal revokes the extraction before it deletes anything.
            open.cancelAndJoin()
            model.cancelNarrationExtraction()
            carryOn.countDown()

            assertTrue("the removal could not reach the extraction, which wrote on", revoked.await())
        } finally {
            opening.tearDown()
        }
    }

    /** Installing narration again silences the coordinator it replaces. */
    @Test
    fun attachingAgainSilencesThePrevious() = run { scope ->
        val opening = ReaderOpening(fallbackBook())
        val directory = temporaryDirectory("issa-attach-again")
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            model.open(pageSize)
            val previous = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val entry = checkNotNull(timeline.entries.firstOrNull())
            assertTrue(model.resumeNarration(entry, playing = true))
            assertTrue(previous.player.isPlaying)

            val files = AudioExtraction.extractAudio(checkNotNull(model.epubPackage), timeline, "attach-again", directory)
            model.attachNarration(timeline, files)

            assertNotSame(previous, model.readalong)
            assertFalse("the replaced coordinator is still talking", previous.player.isPlaying)
        } finally {
            directory.deleteRecursively()
            opening.tearDown()
        }
    }

    // R-52: a page turn that lands nowhere

    /** A page turn that lands nowhere names the chapter that stopped it, not the last one tried. */
    @Test
    fun aTurnThatLandsNowhereNamesTheBlocker() = run { scope ->
        val opening = ReaderOpening(
            TestEpub.data(
                chapters = listOf(
                    TestEpub.Chapter("ch1", "Chapter One", prose("first")),
                    TestEpub.Chapter("ch2", "Chapter Two", prose("second")),
                    TestEpub.Chapter("ch3", "Chapter Three", "<p>A <b>broken chapter</p>"),
                    TestEpub.Chapter("ch4", "Chapter Four", "<p>Another <i>broken chapter</p>"),
                ),
            ),
        )
        try {
            val model = opening.model(scope)
            model.enqueuePosition = { _, _, _ -> true }
            model.open(pageSize)
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            model.go(toChapter = 1)
            model.pageIndex = maxOf(model.pageCount - 1, 0)

            model.nextPage()

            assertEquals("there was nowhere to land", 1, model.chapterIndex)
            val notice = checkNotNull(model.chapterNotice)
            assertTrue("the notice named ${notice.message}", notice.message.contains("Chapter Three"))
        } finally {
            opening.tearDown()
        }
    }
}
