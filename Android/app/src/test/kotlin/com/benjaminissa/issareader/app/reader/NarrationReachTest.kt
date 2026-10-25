package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.Answer
import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ReaderOpening
import com.benjaminissa.issareader.app.SharedFixtures
import com.benjaminissa.issareader.app.SilentAudio
import com.benjaminissa.issareader.app.StubServer
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.temporaryDirectory
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.testServices
import com.benjaminissa.issareader.epub.SmilParser
import com.benjaminissa.issareader.playback.AudioExtraction
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * How far a page turn may drag the voice. Ported from the first suite of
 * `NarrationReachTests.swift`.
 */
class NarrationReachTest : AppSuite() {
    private val pageTop = 1_000
    private val pageLength = 400
    private val chapter = 10_000

    /** The reach is the page in hand and the one after it. */
    @Test
    fun reachIsTwoPages() {
        val range = checkNotNull(NarrationReach.range(pageTop, pageLength, chapter))
        assertEquals(pageTop, range.location)
        assertEquals(pageLength * 2, range.length)
        // The regression, stated as a number: the whole rest of the chapter.
        assertTrue(range.length < chapter - pageTop)
    }

    /** The reach is measured in this book's own pages, not the book's length. */
    @Test
    fun reachFollowsThePageSize() {
        val television = checkNotNull(NarrationReach.range(0, 300, chapter))
        val phone = checkNotNull(NarrationReach.range(0, 1_200, chapter))
        assertEquals(600, television.length)
        assertEquals(2_400, phone.length)
    }

    /** The reach stops at the end of the chapter. */
    @Test
    fun reachIsClippedToTheChapter() {
        val range = checkNotNull(NarrationReach.range(9_500, pageLength, chapter))
        assertEquals(9_500, range.location)
        assertEquals(500, range.length)
        assertEquals(chapter, range.end)
    }

    /** A page beginning at or past the end of the chapter reaches nothing. */
    @Test
    fun nothingBeyondTheEnd() {
        assertNull(NarrationReach.range(chapter, pageLength, chapter))
        assertNull(NarrationReach.range(chapter + 1, pageLength, chapter))
        assertNull(NarrationReach.range(-1, pageLength, chapter))
        assertNull(NarrationReach.restOfChapter(chapter, chapter))
    }

    /** A page holding no characters reaches nothing. */
    @Test
    fun anEmptyPageReachesNothing() {
        assertNull(NarrationReach.range(pageTop, 0, chapter))
    }

    /** The read-aloud path still runs to the end of the chapter. */
    @Test
    fun restOfChapterIsUnbounded() {
        val range = checkNotNull(NarrationReach.restOfChapter(pageTop, chapter))
        assertEquals(pageTop, range.location)
        assertEquals(chapter, range.end)
    }
}

/**
 * Which chapter's sentence an id names: ids are unique per document, not per
 * book. Ported from the second suite of `NarrationReachTests.swift`.
 */
class DocumentScopedNarrationTest : AppSuite() {
    private fun chapter(id: String, name: String) = TestEpub.Chapter(
        id = id, title = "Chapter $name",
        body = "<p><span id=\"s0\">The opening sentence of chapter $name, long enough to read.</span></p>" +
            "<p><span id=\"s1\">The second sentence of chapter $name, which follows it.</span></p>",
        narrated = listOf("s0", "s1"),
    )

    private val one = chapter("one", "One")
    private val two = chapter("two", "Two")

    private class Opened(val model: ReaderModel, val directory: File, val server: StubServer) {
        fun tearDown() {
            model.readalong?.player?.pause()
            directory.deleteRecursively()
            server.close()
        }
    }

    /** The book open at chapter two, its narration extracted and hooked up, the voice not yet started. */
    private suspend fun atChapterTwo(scope: CoroutineScope): Opened {
        val server = StubServer { Answer(404) }
        val model = ReaderModel(
            SharedFixtures.book("Shared ids", uuid = "document-scoped-uuid"),
            server.session(),
            testServices(scope),
        )
        model.enqueuePosition = { _, _, _ -> true }
        model.epubPackage = TestEpub.epubPackage(chapters = listOf(one, two), audio = SilentAudio.wav(30))
        val epubPackage = checkNotNull(model.epubPackage)
        val timeline = SmilParser.timeline(epubPackage)
        assertEquals("both chapters' overlays have to be in the book", 4, timeline.entries.size)
        // `resize` before `go`: it records the page size, and its own relayout
        // is a no-op while there is no layout yet.
        model.resize(PageSize(340.0, 560.0))
        model.go(toChapter = 1)
        val directory = temporaryDirectory("issa-document-scoped")
        val files = AudioExtraction.extractAudio(epubPackage, timeline, "document-scoped", directory)
        model.attachNarration(timeline, files)
        return Opened(model, directory, server)
    }

    /** Playing the page plays this chapter's sentence, not the first with its id. */
    @Test
    fun playingThePagePlaysThisChapter() = mainTest {
        val scope = testScope()
        val opened = atChapterTwo(scope)
        try {
            opened.model.playFirstSentenceOnPage()

            assertEquals(TestEpub.href(two), opened.model.readalong?.activeEntry?.textHref)
            assertEquals("s0", opened.model.readalong?.activeEntry?.fragmentId)
            assertEquals("and the page stays in chapter two", 1, opened.model.chapterIndex)
        } finally {
            opened.tearDown()
            scope.close()
        }
    }

    /** The play button starts in this chapter. */
    @Test
    fun thePlayButtonStartsHere() = mainTest {
        val scope = testScope()
        val opened = atChapterTwo(scope)
        try {
            opened.model.togglePlayback()

            assertEquals(TestEpub.href(two), opened.model.readalong?.activeEntry?.textHref)
            assertEquals(true, opened.model.readalong?.player?.isPlaying)
        } finally {
            opened.tearDown()
            scope.close()
        }
    }

    /** Playing from the visible page stays in this chapter. */
    @Test
    fun playingFromTheVisiblePageStaysHere() = mainTest {
        val scope = testScope()
        val opened = atChapterTwo(scope)
        try {
            opened.model.playFromVisiblePage()

            assertEquals(TestEpub.href(two), opened.model.readalong?.activeEntry?.textHref)
            assertEquals(1, opened.model.chapterIndex)
        } finally {
            opened.tearDown()
            scope.close()
        }
    }
}

/**
 * R-51: narration finds its sentence only in its own chapter. Ported from
 * `NarrationScopeTests.swift`.
 */
class NarrationScopeTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)
    private val chapterOne = "OEBPS/ch1.xhtml"

    private val filler = (1..14).joinToString("") {
        "<p>Paragraph $it runs on at some length, so that the chapter it belongs to fills more than " +
            "one page of the reader at this size and a later sentence lands on a later page.</p>"
    }

    /** Both chapters number their sentences s0, s1, s2; in chapter two, s2 is pages after s0. */
    private fun chapters(firstBroken: Boolean = false) = listOf(
        TestEpub.Chapter(
            id = "ch1", title = "Chapter One",
            body = if (firstBroken) {
                "<p><span id=\"s0\">One.</span> <b>Broken <span id=\"s1\">here</span> <span id=\"s2\">and here.</span></p>"
            } else {
                "<p><span id=\"s0\">The first sentence of chapter one.</span> " +
                    "<span id=\"s1\">The second sentence of it.</span> <span id=\"s2\">And the third.</span></p>"
            },
            narrated = listOf("s0", "s1", "s2"),
        ),
        TestEpub.Chapter(
            id = "ch2", title = "Chapter Two",
            body = "<p><span id=\"s0\">Chapter two begins here.</span></p>" +
                "<p><span id=\"s1\">Then a second sentence.</span></p>" + filler +
                "<p><span id=\"s2\">And far below, its third.</span></p>",
            narrated = listOf("s0", "s1", "s2"),
        ),
    )

    private suspend fun opened(scope: CoroutineScope, firstBroken: Boolean = false): Pair<ReaderModel, ReaderOpening> {
        val opening = ReaderOpening(TestEpub.data(chapters = chapters(firstBroken), audio = SilentAudio.wav(10)))
        val model = opening.model(scope)
        model.enqueuePosition = { _, _, _ -> true }
        model.open(pageSize)
        return model to opening
    }

    /** A sentence in another chapter neither turns this chapter's page nor lights in it. */
    @Test
    fun anotherChaptersSentenceStaysThere() = mainTest {
        val scope = testScope()
        val (model, opening) = opened(scope)
        try {
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val first = checkNotNull(timeline.exactEntryForFragment("s0", chapterOne))
            val third = checkNotNull(timeline.exactEntryForFragment("s2", chapterOne))
            model.go(toChapter = 0)
            assertTrue(readalong.prepare(first))

            // The reader reads on into chapter two while the voice stays behind.
            model.go(toChapter = 1)
            assertEquals(1, model.chapterIndex)
            assertTrue(
                "chapter two's s2 has to be on a later page for this to show anything",
                (model.layout?.pageContainingFragment("s2")?.index ?: 0) > 0,
            )
            val page = model.pageIndex

            assertTrue(readalong.prepare(third))

            assertEquals(1, model.chapterIndex)
            assertEquals("chapter one's s2 turned chapter two's page to its own s2", page, model.pageIndex)
            assertNull("chapter two's s2 is highlighted for a sentence spoken in chapter one", model.activeFragmentId)
        } finally {
            opening.tearDown()
            scope.close()
        }
    }

    /** Catching up with a voice whose chapter will not open leaves this chapter's page alone. */
    @Test
    fun catchingUpStaysInTheVoicesChapter() = mainTest {
        val scope = testScope()
        val (model, opening) = opened(scope, firstBroken = true)
        try {
            assertEquals(ReaderModel.Phase.Ready, model.phase)
            assertEquals(
                "chapter one will not open, so the book opens on chapter two",
                "OEBPS/ch2.xhtml", model.epubPackage?.spine?.get(model.chapterIndex)?.href,
            )
            val readalong = checkNotNull(model.readalong)
            val timeline = checkNotNull(model.timeline)
            val third = checkNotNull(timeline.exactEntryForFragment("s2", chapterOne))

            model.setReaderVisible(false)
            assertTrue(readalong.prepare(third))
            model.pageIndex = 0
            model.setReaderVisible(true)
            model.syncToNarration()

            assertEquals("the voice's s2 in chapter one turned chapter two's page", 0, model.pageIndex)
        } finally {
            opening.tearDown()
            scope.close()
        }
    }
}

/**
 * Where a turn past the end of a chapter lands — the rule the page turn and
 * the neighbouring-chapter prefetch both walk. Ported from
 * `ChapterWalkTests.swift`.
 */
class ChapterWalkTest : AppSuite() {
    private suspend fun walk(chapters: List<ChapterWalk.Attempt>, from: Int, step: Int = 1): Pair<ChapterWalk.Landing, List<Int>> {
        val tried = ArrayList<Int>()
        val landing = ChapterWalk.walk(from, step, chapters.size) { index ->
            tried.add(index)
            chapters[index]
        }
        return landing to tried
    }

    private val content = ChapterWalk.Attempt.CONTENT
    private val empty = ChapterWalk.Attempt.EMPTY
    private val unreadable = ChapterWalk.Attempt.UNREADABLE
    private val abandoned = ChapterWalk.Attempt.ABANDONED

    /** It stops on the first chapter with something on it. */
    @Test
    fun firstContent() = mainTest {
        val (landing, tried) = walk(listOf(content, empty, empty, content, content), from = 1)
        assertEquals(ChapterWalk.Landing(chapter = 3, skipped = emptyList()), landing)
        assertEquals(listOf(1, 2, 3), tried)
    }

    /** It steps over a chapter that will not open, and names it. */
    @Test
    fun stepsOverUnreadable() = mainTest {
        val (landing, _) = walk(listOf(content, unreadable, content), from = 1)
        assertEquals(ChapterWalk.Landing(chapter = 2, skipped = listOf(1)), landing)
    }

    /** Backwards, the same. */
    @Test
    fun backwards() = mainTest {
        val (landing, tried) = walk(listOf(content, unreadable, empty, content), from = 2, step = -1)
        assertEquals(ChapterWalk.Landing(chapter = 0, skipped = listOf(1)), landing)
        assertEquals(listOf(2, 1, 0), tried)
    }

    /** It gives up after eight, on the last one that opened. */
    @Test
    fun limit() = mainTest {
        val chapters = listOf(content) + List(9) { empty } + listOf(content)
        val (landing, tried) = walk(chapters, from = 1)
        assertEquals((1..8).toList(), tried)
        assertEquals(ChapterWalk.Landing(chapter = 8, skipped = emptyList()), landing)
    }

    /** Eight chapters that will not open land nowhere. */
    @Test
    fun nowhere() = mainTest {
        val chapters = listOf(content) + List(8) { unreadable } + listOf(content)
        val (landing, _) = walk(chapters, from = 1)
        assertNull(landing.chapter)
        assertEquals((1..8).toList(), landing.skipped)
    }

    /** It stops at the end of the book. */
    @Test
    fun spineEnd() = mainTest {
        val (landing, tried) = walk(listOf(content, empty, empty), from = 1)
        assertEquals(listOf(1, 2), tried)
        assertEquals(ChapterWalk.Landing(chapter = 2, skipped = emptyList()), landing)
    }

    /** A walk that is no longer wanted stops at once and lands nowhere. */
    @Test
    fun abandoned() = mainTest {
        val (landing, tried) = walk(listOf(content, unreadable, abandoned, content), from = 1)
        assertEquals(listOf(1, 2), tried)
        assertTrue(landing.abandoned)
        assertNull(landing.chapter)
    }

    /** Fewer than four characters is empty, but a plate is content. */
    @Test
    fun emptiness() {
        assertTrue(ChapterWalk.isEmpty("  \n "))
        assertTrue(ChapterWalk.isEmpty("abc"))
        assertTrue(!ChapterWalk.isEmpty("￼"))
        assertTrue(!ChapterWalk.isEmpty("Once"))
    }
}
