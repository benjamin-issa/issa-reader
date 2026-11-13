package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.AppSuite
import com.benjaminissa.issareader.app.ReaderOpening
import com.benjaminissa.issareader.app.TestEpub
import com.benjaminissa.issareader.app.close
import com.benjaminissa.issareader.app.mainTest
import com.benjaminissa.issareader.app.testScope
import com.benjaminissa.issareader.app.waitUntil
import com.benjaminissa.issareader.core.model.ReadiumLocator
import com.benjaminissa.issareader.core.model.StoredPosition
import kotlinx.coroutines.CoroutineScope
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * An unmoved page is not written again after the pages were laid out afresh.
 * A rotation, a resized window or a change of type puts the same words on a
 * page that starts somewhere else, and a save that took that for a move would
 * stamp the place with a newer time than one read on another device.
 */
class SettledPlaceTest : AppSuite() {
    private val pageSize = PageSize(340.0, 560.0)
    private val openings = ArrayList<ReaderOpening>()

    @After
    fun tearDown() = openings.forEach { it.tearDown() }

    private fun paragraphs(prefix: String): String =
        (0 until 60).joinToString("") { "<p>Sentence $it of the $prefix chapter, long enough to take a line or two of the page. </p>" }

    private fun run(body: suspend (CoroutineScope) -> Unit) = mainTest {
        val scope = testScope()
        try {
            body(scope)
        } finally {
            scope.close()
        }
    }

    /** A reader restored to the middle of the first chapter, writing into [written]. */
    private suspend fun restored(scope: CoroutineScope, written: MutableList<ReadiumLocator>): ReaderModel {
        val chapters = listOf(TestEpub.Chapter("one", "One", paragraphs("a")), TestEpub.Chapter("two", "Two", paragraphs("b")))
        val stored = StoredPosition(
            locator = ReadiumLocator(
                href = "OEBPS/one.xhtml",
                type = "application/xhtml+xml",
                locations = ReadiumLocator.Locations(progression = 0.5, totalProgression = 0.25),
            ),
            timestamp = 1_000.0,
        )
        val opening = ReaderOpening(TestEpub.data(chapters = chapters), position = stored).also { openings += it }
        val model = opening.model(scope)
        model.enqueuePosition = { locator, _, _ ->
            written.add(locator)
            true
        }
        model.open(pageSize)
        assertEquals(ReaderModel.Phase.Ready, model.phase)
        assertTrue("restored past the first page", model.pageIndex > 0)
        return model
    }

    @Test
    fun `a relayout at a new page size writes nothing`() = run { scope ->
        val written = ArrayList<ReadiumLocator>()
        val model = restored(scope, written)
        model.saveProgress()
        assertEquals("the restored place is the stored one", 0, written.size)

        val restoredAt = checkNotNull(model.currentPage).characterRange.location

        model.resize(PageSize(300.0, 410.0))
        // The arrangement the rule is for: the page now shown starts somewhere
        // else and still holds the place that was settled.
        val now = checkNotNull(model.currentPage).characterRange
        assertTrue("the page start did not move ($restoredAt)", now.location != restoredAt)
        assertTrue("the restored offset $restoredAt is not inside $now", restoredAt in now)
        model.saveProgress()

        assertEquals("the same words on another page are not a move", 0, written.size)
    }

    @Test
    fun `a page turned after a relayout is written once`() = run { scope ->
        val written = ArrayList<ReadiumLocator>()
        val model = restored(scope, written)
        model.resize(PageSize(300.0, 410.0))
        model.saveProgress()
        assertEquals(0, written.size)

        model.nextPage()
        model.saveProgress()
        model.saveProgress()

        assertEquals(1, written.size)
    }

    @Test
    fun `a change of type size writes nothing`() = run { scope ->
        val written = ArrayList<ReadiumLocator>()
        val model = restored(scope, written)
        val before = model.layoutRevision

        model.style = model.style.copy(fontSize = model.style.fontSize + 4)
        assertTrue("the chapter was laid out again", waitUntil { model.layoutRevision != before })
        model.saveProgress()

        assertEquals(0, written.size)
    }

    @Test
    fun `a page turned after a change of type size is written`() = run { scope ->
        val written = ArrayList<ReadiumLocator>()
        val model = restored(scope, written)

        val before = model.layoutRevision
        model.style = model.style.copy(fontSize = model.style.fontSize + 4)
        assertTrue(waitUntil { model.layoutRevision != before })
        model.saveProgress()
        assertEquals(0, written.size)

        model.nextPage()
        model.saveProgress()

        assertEquals(1, written.size)
    }
}
