package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ReaderOpening
import com.benjaminissa.issareader.app.SilentAudio
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import kotlinx.coroutines.CoroutineScope
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reader's place holds through a run of reflows, and the pages it draws are
 * the ones that run left. From `SpreadPagingTests.swift`, which found these on
 * iPhone Duo's poses. Android has no spread, but a window settling after a
 * rotation, a split screen or a fold reflows just the same.
 */
class ReflowPlaceTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)

    /** A run of layouts in under a second, none of them the reader's, ending where it began so the place can be asked for exactly. */
    private val settling = listOf(
        PageSize(640.0, 300.0), PageSize(250.0, 310.0), PageSize(300.0, 290.0), PageSize(660.0, 280.0),
        PageSize(660.0, 240.0), PageSize(280.0, 260.0), pageSize,
    )

    private fun paragraphs(prefix: String, sentenceLength: Int = 1, narrated: Boolean = false): String =
        (0 until 40).joinToString("") { index ->
            val sentence = "Sentence $index of the $prefix chapter, long enough to take a line or two of the page. "
            val text = sentence.repeat(sentenceLength)
            if (narrated) "<p><span id=\"$prefix$index\">$text</span></p>" else "<p>$text</p>"
        }

    private val openings = ArrayList<ReaderOpening>()

    @After
    fun tearDown() = openings.forEach { it.tearDown() }

    private suspend fun opened(scope: CoroutineScope): ReaderModel {
        val opening = ReaderOpening(
            TestEpub.data(
                chapters = listOf(
                    TestEpub.Chapter("one", "One", paragraphs("a")),
                    TestEpub.Chapter("two", "Two", paragraphs("b")),
                ),
            ),
        ).also { openings += it }
        val model = opening.model(scope)
        model.enqueuePosition = { _, _, _ -> true }
        model.open(pageSize)
        assertEquals(ReaderModel.Phase.Ready, model.phase)
        assertTrue("the chapter has to run to several pages", model.pageCount >= 5)
        return model
    }

    private suspend fun settle(model: ReaderModel) {
        for (size in settling) model.resize(size)
    }

    private fun run(body: suspend (CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        try {
            body(scope)
        } finally {
            scope.close()
        }
    }

    /**
     * Each layout snapped to the start of the page holding the place, and that
     * start became the next layout's place, so a run of them walked the reader
     * back to the top of the chapter.
     */
    @Test
    fun `a page size settling through several layouts keeps the place`() = run { scope ->
        val model = opened(scope)
        model.nextPage()
        model.nextPage()
        val page = checkNotNull(model.currentPage)

        settle(model)

        assertEquals(page.index, model.pageIndex)
        assertEquals(page.characterRange.location, model.currentPage?.characterRange?.location)
    }

    /** The place held through a settling is the reader's until they move it. */
    @Test
    fun `a turn after a layout settled is the place the next one keeps`() = run { scope ->
        val model = opened(scope)
        model.nextPage()
        settle(model)
        model.nextPage()
        val page = checkNotNull(model.currentPage)

        settle(model)

        assertEquals(page.index, model.pageIndex)
    }

    /** A chapter of its own has offsets of its own. */
    @Test
    fun `another chapter does not inherit the place held in the last one`() = run { scope ->
        val model = opened(scope)
        model.nextPage()
        settle(model)
        model.go(toChapter = 1)
        assertEquals(0, model.pageIndex)

        settle(model)

        assertEquals(0, model.pageIndex)
        assertEquals(1, model.chapterIndex)
    }

    /**
     * An anchor past every page's range is at the end of the chapter, not the
     * top of it. The parser trims trailing newlines, so no chapter it makes
     * ends on an empty page today, which is why this asks the rule itself
     * rather than building one.
     */
    @Test
    fun `an anchor at the end of a chapter is on its last page, and the rest on their own`() = run { scope ->
        val model = opened(scope)
        val pages = checkNotNull(model.layout).pages
        val last = pages.last()
        val middle = pages[pages.size / 2]

        assertEquals(0, ReaderModel.pageIndexHolding(0, pages))
        assertEquals(middle.index, ReaderModel.pageIndexHolding(middle.characterRange.location, pages))
        assertEquals(last.index, ReaderModel.pageIndexHolding(last.characterRange.end, pages))
    }

    /**
     * A style change lays the chapter out again and lands on a page number of
     * its own. If that number is the one a reflow left, the place held from
     * before the change would be taken for the reader's.
     */
    @Test
    fun `a reload does not inherit the place held before it`() = run { scope ->
        val model = opened(scope)
        model.nextPage()
        model.nextPage()
        model.resize(PageSize(pageSize.width, pageSize.height + 30))
        val heldPage = model.pageIndex
        val heldWords = checkNotNull(model.currentPage).characterRange.location

        // Bigger type, so the words held are on a later page than they were.
        val revision = model.layoutRevision
        model.style = model.style.copy(fontSize = model.style.fontSize * 2)
        assertTrue(waitUntil { model.layoutRevision != revision })
        // And the reader on the page number the reflow left, which is all the
        // held place is keyed to.
        model.pageIndex = heldPage
        val page = checkNotNull(model.currentPage)
        assertTrue("the held words have to have moved off this page for this to test anything", heldWords !in page.characterRange)

        model.resize(PageSize(pageSize.width, pageSize.height + 31))

        assertTrue(page.characterRange.location in checkNotNull(model.currentPage).characterRange)
    }

    /** No accessibility query can see a canvas, so this asks what Compose asks: is this snapshot equal to the last. */
    @Test
    fun `a layout that keeps the page number still redraws the page`() = run { scope ->
        val model = opened(scope)
        assertEquals(0, model.pageIndex)
        val before = checkNotNull(model.currentSnapshot())

        model.resize(PageSize(pageSize.width, pageSize.height - 20))

        assertEquals("the page number has to be what stayed the same", 0, model.pageIndex)
        assertNotEquals(before.revision, model.currentSnapshot()?.revision)
    }

    /** The offset is the sentence's end, so a number taken from the page on screen named the page before the one the offset is on. */
    @Test
    fun `Ask numbers the page a sentence crossing a break ends on`() = run { scope ->
        val server = StubServer { Answer(404) }
        val directory = temporaryDirectory("issa-reflow-ask")
        try {
            val chapter = TestEpub.Chapter(
                "one", "One", paragraphs("a", sentenceLength = 3, narrated = true), narrated = (0 until 40).map { "a$it" },
            )
            val model = ReaderModel(SharedFixtures.book("Ask", uuid = "reflow-ask-uuid"), server.session(), testServices(scope))
            model.enqueuePosition = { _, _, _ -> true }
            model.epubPackage = TestEpub.epubPackage(chapters = listOf(chapter), audio = SilentAudio.wav(60))
            val epubPackage = checkNotNull(model.epubPackage)
            val timeline = SmilParser.timeline(epubPackage)
            model.resize(pageSize)
            model.go(toChapter = 0)
            model.attachNarration(timeline, AudioExtraction.extractAudio(epubPackage, timeline, "reflow-ask", directory))
            val layout = checkNotNull(model.layout)
            val crossing = (0 until 40).map { "a$it" }.first { fragment ->
                val range = checkNotNull(layout.fragmentRange(fragment))
                layout.pageContainingOffset(range.location)?.index != layout.pageContainingOffset(range.end - 1)?.index
            }
            val range = checkNotNull(layout.fragmentRange(crossing))
            val last = checkNotNull(layout.pageContainingOffset(range.end - 1)).index
            val entry = checkNotNull(timeline.entries.firstOrNull { it.fragmentId == crossing })
            assertTrue(model.resumeNarration(entry, playing = true))

            assertEquals(last + 1, model.readingBoundary()?.pageNumber)
            model.readalong?.player?.pause()
        } finally {
            directory.deleteRecursively()
            server.close()
        }
    }
}
