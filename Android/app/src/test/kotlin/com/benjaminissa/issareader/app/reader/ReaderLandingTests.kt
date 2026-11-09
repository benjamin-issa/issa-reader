package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.core.model.AudioAnchor
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.testing.Fixtures
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Which chapter opening a book lands on. Ported from `ReaderLandingTests.swift`.
 */
class ReaderLandingTest : AppSuite() {
    private fun epubPackage(): EpubPackage = EpubPackage.open(Fixtures.epub("readalong.epub"))

    private fun audioLocator(href: String, progress: Double) = ReadiumLocator(
        href = href, type = "audio/mpeg", locations = ReadiumLocator.Locations(totalProgression = progress),
    )

    /** An audio position written by the car lands on the sentence its anchor names. */
    @Test
    fun anAudioPositionWrittenByTheCarLandsOnTheSentenceItsAnchorNames() {
        val epubPackage = epubPackage()
        val landing = ReaderModel.resolveLanding(
            stored = audioLocator("OEBPS/Audio/track2.mp3", 0.9),
            anchor = AudioAnchor(audioHref = "OEBPS/Audio/track2.mp3", offset = 1.0, writtenAt = 1.0),
            epubPackage = epubPackage, timeline = SmilParser.timeline(epubPackage),
        )

        assertEquals(ReaderModel.Landing.How.AUDIO_ANCHOR, landing.how)
        assertEquals("track two narrates the second chapter", 1, landing.index)
        assertEquals(listOf("ch02-s0"), landing.restoring?.locations?.fragments)
    }

    /** An anchor naming the original upload falls back to progression. */
    @Test
    fun anAnchorNamingTheOriginalUploadFallsBackToProgression() {
        val epubPackage = epubPackage()
        val stored = audioLocator("The Outsider.mp3", 0.5181)
        val landing = ReaderModel.resolveLanding(
            stored = stored,
            anchor = AudioAnchor(audioHref = "The Outsider.mp3", offset = 16.0, writtenAt = 1.0),
            epubPackage = epubPackage, timeline = SmilParser.timeline(epubPackage),
        )

        assertEquals(ReaderModel.Landing.How.PROGRESSION, landing.how)
        val expected = checkNotNull(ReaderModel.spinePosition(0.5181, epubPackage))
        assertEquals(expected.first, landing.index)
    }

    /** A text position is untouched by the anchor. */
    @Test
    fun aTextPositionIsUntouchedByTheAnchor() {
        val epubPackage = epubPackage()
        val stored = ReadiumLocator(
            href = "OEBPS/ch02.xhtml", type = "application/xhtml+xml",
            locations = ReadiumLocator.Locations(fragments = listOf("ch02-s1"), totalProgression = 0.8),
        )
        val landing = ReaderModel.resolveLanding(
            stored = stored,
            anchor = AudioAnchor(audioHref = "OEBPS/Audio/track1.mp3", offset = 0.0, writtenAt = 1.0),
            epubPackage = epubPackage, timeline = SmilParser.timeline(epubPackage),
        )

        assertEquals(ReaderModel.Landing.How.STORED_HREF, landing.how)
        assertEquals(1, landing.index)
        assertEquals("the reader's own locator, not a synthesised one", stored, landing.restoring)
    }
}

/**
 * The line past which the model is never shown anything. Ported from
 * `ReadingBoundaryTests.swift`, less the index's half (see PORTING.md).
 */
class ReadingBoundaryTest : AppSuite() {
    /** Chapter I of the fixture: two wrappers in front are why this is 2. */
    private val chapterI = 2

    /** A reader with a chapter laid out, without a server or a download. */
    private suspend fun opened(scope: CoroutineScope, server: StubServer, spine: Int): ReaderModel {
        val model = ReaderModel(SharedFixtures.book("Alice", uuid = "alice-uuid"), server.session(), testServices(scope))
        model.epubPackage = EpubPackage.open(Fixtures.epub("alice.epub"))
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = spine)
        return model
    }

    /** The boundary is the end of what the page paints. */
    @Test
    fun boundaryIsThePaintedEnd() = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        try {
            val model = opened(scope, server, chapterI)
            val layout = checkNotNull(model.layout)
            val page = checkNotNull(model.currentPage)

            val boundary = checkNotNull(model.readingBoundary())
            assertEquals(chapterI, boundary.spineIndex)
            assertEquals(layout.paintedCharacterRange(page).end, boundary.charOffset)
            assertEquals(1, boundary.pageNumber)
            assertEquals(ReadingBoundary.Kind.PAGE_END, boundary.kind)
        } finally {
            server.close()
            scope.close()
        }
    }

    /** Turning the page moves the boundary with it. */
    @Test
    fun boundaryFollowsThePage() = mainTest {
        val scope = testScope()
        val server = StubServer { Answer(404) }
        try {
            val model = opened(scope, server, chapterI)
            assertTrue("the chapter has to run to more than two pages", model.pageCount > 2)
            val first = checkNotNull(model.readingBoundary())

            model.nextPage()
            val second = checkNotNull(model.readingBoundary())
            assertTrue(second.charOffset > first.charOffset)
            assertEquals(2, second.pageNumber)

            val layout = checkNotNull(model.layout)
            val page = checkNotNull(model.currentPage)
            assertEquals(layout.paintedCharacterRange(page).end, second.charOffset)
        } finally {
            server.close()
            scope.close()
        }
    }
}
