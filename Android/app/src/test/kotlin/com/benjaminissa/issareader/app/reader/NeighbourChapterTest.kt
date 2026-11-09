package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ReaderOpening
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.core.model.Annotation
import com.benjaminissa.issareader.render.HighlighterChoice
import com.benjaminissa.issareader.render.HighlighterPreset
import com.benjaminissa.issareader.render.ReaderTheme
import kotlinx.coroutines.CoroutineScope
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The chapter on the far side of a boundary, laid out before the turn that
 * crosses it — so the turn can slide its first page in like any other.
 * Ported from `NeighbourChapterTests.swift`.
 *
 * The one thing that must never happen is a prepared turn landing somewhere
 * an unprepared one would not, so most of this compares the two on the same book.
 */
class NeighbourChapterTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)

    private fun prose(name: String) =
        "<h1>$name</h1>" + "<p>The words of $name, set down at length so that the chapter runs across more than one page of the reader.</p>".repeat(40)

    private fun content(n: Int) = TestEpub.Chapter("ch$n", "Chapter $n", prose("chapter $n"))

    private fun empty(n: Int) = TestEpub.Chapter("ch$n", "Chapter $n", "<p> </p>")

    private fun broken(n: Int) = TestEpub.Chapter("ch$n", "Chapter $n", "<p>A <b>broken chapter</p>")

    private class Opened(val model: ReaderModel, val opening: ReaderOpening)

    private val opened = ArrayList<Opened>()

    private suspend fun open(scope: CoroutineScope, chapters: List<TestEpub.Chapter>): ReaderModel {
        val opening = ReaderOpening(TestEpub.data(chapters = chapters))
        val model = opening.model(scope)
        model.enqueuePosition = { _, _, _ -> true }
        model.open(pageSize)
        opened.add(Opened(model, opening))
        assertEquals(ReaderModel.Phase.Ready, model.phase)
        // As a reader whose pages slide, on screen.
        model.keepsNeighbours = true
        model.setReaderVisible(true)
        return model
    }

    private fun run(body: suspend (CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        try {
            body(scope)
        } finally {
            opened.forEach { it.opening.tearDown() }
            opened.clear()
            scope.close()
        }
    }

    /** Stands the reader at the edge a turn is about to cross. */
    private suspend fun standAtEdge(model: ReaderModel, chapter: Int, forward: Boolean) {
        model.go(toChapter = chapter)
        model.pageIndex = if (forward) maxOf(model.pageCount - 1, 0) else 0
    }

    private data class Arrival(val chapter: Int, val page: Int, val notice: String?)

    private fun arrival(model: ReaderModel) = Arrival(model.chapterIndex, model.pageIndex, model.chapterNotice?.message)

    /** A book, the chapter to start from, and which way to turn. */
    private class Shape(val name: String, val chapters: () -> List<TestEpub.Chapter>, val start: Int, val forward: Boolean)

    private val shapes = listOf(
        Shape("content, empty, empty, content", { listOf(content(0), empty(1), empty(2), content(3)) }, 0, true),
        Shape("content, broken, content", { listOf(content(0), broken(1), content(2)) }, 0, true),
        Shape("content and nine empty", { listOf(content(0)) + (1..9).map(::empty) + listOf(content(10)) }, 0, true),
        Shape("content and eight broken", { listOf(content(0)) + (1..8).map(::broken) + listOf(content(9)) }, 0, true),
        Shape("back over broken and empty", { listOf(content(0), empty(1), broken(2), content(3)) }, 3, false),
        Shape("the next chapter, plainly", { listOf(content(0), content(1)) }, 0, true),
    )

    /** A prepared turn lands exactly where an unprepared one does, for every shape of book. */
    @Test
    fun landsTheSame() = run { scope ->
        for (shape in shapes) {
            val plain = open(scope, shape.chapters())
            standAtEdge(plain, shape.start, shape.forward)
            if (shape.forward) plain.nextPage() else plain.previousPage()
            val expected = arrival(plain)

            val model = open(scope, shape.chapters())
            standAtEdge(model, shape.start, shape.forward)
            model.prefetchNeighbours()
            model.neighbourSettled(shape.forward)
            val neighbour = checkNotNull(model.neighbours[shape.forward]) { "${shape.name}: the prefetch ran" }
            assertFalse("${shape.name}: the prefetch finished", neighbour.state is ReaderModel.NeighbourState.Pending)
            val prepared = model.neighbourPreview(shape.forward)
            if (shape.forward) model.nextPage() else model.previousPage()

            assertEquals(shape.name, expected, arrival(model))
            if (expected.chapter != shape.start) {
                val page = prepared as? NeighbourPreview.Page
                    ?: return@run fail("${shape.name}: a turn that lands elsewhere has a page to slide in")
                assertSame("${shape.name}: the turn took the chapter already laid out", page.snapshot.layout, model.layout)
            }
        }
    }

    /** Getting a chapter ready changes nothing the reader can see. */
    @Test
    fun commitsNothing() = run { scope ->
        val model = open(scope, listOf(content(0), broken(1), content(2)))
        standAtEdge(model, 0, true)
        val layout = model.layout
        val beforeKey = model.pageKey
        val beforeNotice = model.chapterNotice

        model.prefetchNeighbours()
        model.neighbourSettled(true)

        assertSame(layout, model.layout)
        assertEquals(beforeKey, model.pageKey)
        assertEquals("the broken chapter is said only when a turn steps over it", beforeNotice, model.chapterNotice)
        assertTrue("the chapter after the broken one should be ready", model.neighbourPreview(true) is NeighbourPreview.Page)
    }

    /** Only near a chapter's edge. */
    @Test
    fun onlyNearTheEdge() = run { scope ->
        val model = open(scope, listOf(content(0), content(1), content(2)))
        model.go(toChapter = 1)
        assertTrue("the chapter must be long enough to have a middle", model.pageCount >= 5)
        model.pageIndex = 2
        // The chapter the jump came from is kept as the one before; this is
        // about what a prefetch from the middle adds.
        model.dropNeighbours()

        model.prefetchNeighbours()

        assertTrue(model.neighbours.isEmpty())
    }

    /** A change to the type, the paper or the page size makes it stale. */
    @Test
    fun invalidation() = run { scope ->
        for (change in listOf("size", "theme", "resize")) {
            val model = open(scope, listOf(content(0), content(1)))
            standAtEdge(model, 0, true)
            model.prefetchNeighbours()
            model.neighbourSettled(true)
            assertTrue("$change: ready before the change", model.neighbourPreview(true) is NeighbourPreview.Page)

            when (change) {
                "size" -> model.style = model.style.copy(fontSize = model.style.fontSize + 2)
                "theme" -> model.style = model.style.copy(theme = if (model.style.theme == ReaderTheme.NIGHT) ReaderTheme.PAPER else ReaderTheme.NIGHT)
                else -> {
                    model.resize(PageSize(300.0, 500.0))
                    // Re-paginated: back to the edge in the new pages.
                    model.pageIndex = model.pageCount - 1
                }
            }

            assertEquals(change, NeighbourPreview.Pending, model.neighbourPreview(true))
            assertTrue(change, model.neighbours.isEmpty())
        }
    }

    /** The highlighter colours the read-along block as it is drawn; nothing about it is laid out. */
    @Test
    fun highlighterKeeps() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        model.prefetchNeighbours()
        model.neighbourSettled(true)

        model.style = model.style.copy(
            highlighters = model.style.highlighters + (model.style.theme to HighlighterChoice.Preset(HighlighterPreset.entries.last())),
        )

        assertTrue("a highlighter change dropped the prepared chapter", model.neighbourPreview(true) is NeighbourPreview.Page)
    }

    /** A jump elsewhere leaves nothing behind. */
    @Test
    fun jumpDrops() = run { scope ->
        val model = open(scope, listOf(content(0), content(1), content(2), content(3)))
        standAtEdge(model, 0, true)
        model.prefetchNeighbours()
        model.neighbourSettled(true)
        assertTrue(model.neighbours.isNotEmpty())

        model.go(toChapter = 3)

        assertTrue(model.neighbours.isEmpty())
    }

    /** One overtaken while it was being prepared is thrown away. */
    @Test
    fun staleInFlight() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        model.whilePreparingNeighbour = { model.style = model.style.copy(fontSize = model.style.fontSize + 2) }

        model.prefetchNeighbours()
        model.neighbourSettled(true)

        assertNull("the change landed while it was being prepared", model.whilePreparingNeighbour)
        assertTrue("and what it prepared was thrown away", model.neighbours.isEmpty())
    }

    /** The chapter just left is ready to turn back to, without reading it again. */
    @Test
    fun leftChapterKept() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        val left = model.layout

        model.nextPage()

        val page = model.neighbourPreview(false) as? NeighbourPreview.Page
            ?: return@run fail("turning back would have to read the chapter again")
        assertSame(left, page.snapshot.layout)
        assertEquals("its last page", (left?.pages?.size ?: 0) - 1, page.snapshot.page.index)
        model.previousPage()
        assertEquals(0, model.chapterIndex)
        assertSame(left, model.layout)
    }

    /** A highlight on the next chapter's first page is on the page sliding in. */
    @Test
    fun highlightsCome() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        model.go(toChapter = 1)
        assertNotNull(model.annotatePage(Annotation.Tint.TANGERINE))
        standAtEdge(model, 0, true)
        // The jump back kept chapter 1 as the neighbour, marks and all; this
        // is about the prefetch finding them.
        model.dropNeighbours()

        model.prefetchNeighbours()
        model.neighbourSettled(true)

        val page = model.neighbourPreview(true) as? NeighbourPreview.Page ?: return@run fail("not ready")
        assertTrue(page.snapshot.annotations.isNotEmpty())
    }

    /** At the ends of the book there is nothing to slide in. */
    @Test
    fun bookEnds() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 1, true)
        assertEquals(NeighbourPreview.None, model.neighbourPreview(true))
        standAtEdge(model, 0, false)
        assertEquals(NeighbourPreview.None, model.neighbourPreview(false))
    }

    /** A chapter re-flowed for a new page size is not kept to turn back to. */
    @Test
    fun reflowedNotKept() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        model.resize(PageSize(300.0, 500.0))
        model.pageIndex = model.pageCount - 1

        model.nextPage()

        assertEquals(1, model.chapterIndex)
        assertEquals(NeighbourPreview.Pending, model.neighbourPreview(false))
    }

    /** With None nothing beyond the chapter on screen is kept. */
    @Test
    fun noneKeepsNothing() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        model.keepsNeighbours = false
        standAtEdge(model, 0, true)

        model.prefetchNeighbours()
        model.nextPage()

        assertTrue(model.neighbours.isEmpty())
    }

    /** Off screen, nothing is prepared. */
    @Test
    fun notWhileHidden() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        model.setReaderVisible(false)

        model.prefetchNeighbours()

        assertTrue(model.neighbours.isEmpty())
    }

    /** A neighbour is let go once the reader has moved away from its edge. */
    @Test
    fun farReleased() = run { scope ->
        val model = open(scope, listOf(content(0), content(1)))
        standAtEdge(model, 0, true)
        model.dropNeighbours()
        model.prefetchNeighbours()
        model.neighbourSettled(true)
        assertNotNull(model.neighbours[true])

        model.pageIndex = 2
        model.prefetchNeighbours()

        assertNull(model.neighbours[true])
    }
}
