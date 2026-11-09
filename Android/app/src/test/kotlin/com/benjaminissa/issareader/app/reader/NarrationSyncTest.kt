package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Coming back to a book whose voice was paused. Ported from
 * `NarrationSyncTests.swift`.
 */
class NarrationSyncTest : AppSuite() {
    private val chapterOne = "OEBPS/ch01.xhtml"

    private class Fixture(val model: ReaderModel, val directory: File, val server: StubServer) {
        fun tearDown() {
            model.readalong?.player?.pause()
            directory.deleteRecursively()
            server.close()
        }
    }

    /**
     * The read-along fixture, open at chapter one with its narration hooked up,
     * the voice paused on chapter one's first sentence, and the reader read on
     * silently into chapter two.
     */
    private suspend fun pausedAndReadOn(scope: CoroutineScope): Fixture {
        val server = StubServer { Answer(404) }
        val model = ReaderModel(SharedFixtures.book("Fixture", uuid = "narration-sync-uuid"), server.session(), testServices(scope))
        model.enqueuePosition = { _, _, _ -> true }
        model.epubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = 0)
        val directory = temporaryDirectory("issa-narration-sync")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "narration-sync", directory)
        model.attachNarration(timeline, files)

        val first = checkNotNull(timeline.firstEntryInDocument(chapterOne))
        assertTrue(model.resumeNarration(first, playing = false))
        assertEquals(false, model.readalong?.player?.isPlaying)
        assertEquals(0, model.chapterIndex)
        // Chapter one is a single page at this size, so the next page is the next chapter.
        model.nextPage()
        assertEquals("the reader has read on, past the paused sentence", 1, model.chapterIndex)
        return Fixture(model, directory, server)
    }

    /** F02#5: a paused voice does not turn the reader back when they return. */
    @Test
    fun aPausedVoiceLeavesThePageAlone() = mainTest {
        val scope = testScope()
        val fixture = pausedAndReadOn(scope)
        try {
            fixture.model.setReaderVisible(false)
            fixture.model.setReaderVisible(true)
            fixture.model.syncToNarration()

            assertEquals("the reader keeps the chapter they read on to", 1, fixture.model.chapterIndex)
        } finally {
            fixture.tearDown()
            scope.close()
        }
    }

    /** A voice moved while the reader was away is caught up with, though paused. */
    @Test
    fun aVoiceMovedWhileAwayIsFollowed() = mainTest {
        val scope = testScope()
        val fixture = pausedAndReadOn(scope)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val first = checkNotNull(readalong.activeEntry)
            val later = checkNotNull(timeline.entries.firstOrNull { it.textHref == chapterOne && it != first })

            model.setReaderVisible(false)
            assertTrue(readalong.prepare(later))
            model.setReaderVisible(true)
            model.syncToNarration()

            assertEquals("the page catches up with where the voice got to", 0, model.chapterIndex)
        } finally {
            fixture.tearDown()
            scope.close()
        }
    }

    /** A voice still playing is caught up with. */
    @Test
    fun aPlayingVoiceIsFollowed() = mainTest {
        val scope = testScope()
        val fixture = pausedAndReadOn(scope)
        try {
            val model = fixture.model
            val readalong = checkNotNull(model.readalong)

            model.setReaderVisible(false)
            readalong.player.play()
            model.setReaderVisible(true)
            model.syncToNarration()

            assertEquals(0, model.chapterIndex)
        } finally {
            fixture.tearDown()
            scope.close()
        }
    }
}
