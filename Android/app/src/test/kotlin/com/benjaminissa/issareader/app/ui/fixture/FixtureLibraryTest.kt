package com.benjaminissa.issareader.app.ui.fixture

import com.benjaminissa.issareader.core.sync.LibraryArrangement
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The sweep's fixture has to survive the same decode a real catalogue does:
 * Swift's `FixtureLibraryTests`. A nested decode failure discards the whole
 * array, and the sweep then measures an empty library's chrome.
 */
class FixtureLibraryTest {
    private val books get() = FixtureLibrary.books

    @Test
    fun `every fixture book decodes, not merely some of them`() {
        assertEquals("a nested decode failure throws the whole array away", 6, books.size)
    }

    /** The Reading tab waits for the Continue card, so at least one book must be genuinely in progress. */
    @Test
    fun `at least one book is on the Reading shelf, or the sweep has nothing to wait for`() {
        val reading = books.filter { LibraryArrangement.stage(it) == LibraryArrangement.Stage.READING }
        assertFalse("the Continue card never appears", reading.isEmpty())
        assertTrue(reading.all { it.position != null })
    }

    /** The rails the fixture exists to put on screen. */
    @Test
    fun `the shelves and rails the sweep measures are all non-empty`() {
        val shelves = books.groupBy { LibraryArrangement.stage(it) }
        assertFalse("Reading shelf", shelves[LibraryArrangement.Stage.READING].isNullOrEmpty())
        assertFalse("To read shelf", shelves[LibraryArrangement.Stage.TO_READ].isNullOrEmpty())
        assertFalse("Finished shelf", shelves[LibraryArrangement.Stage.FINISHED].isNullOrEmpty())
        assertTrue("the Recently added rail filters on a createdAt", books.all { it.createdAt != null })
        val series = books.flatMap { it.series }.groupBy { it.name }
        assertTrue("a one-book series is not a series", series.values.any { it.size >= 2 })
    }

    /** The locator has to name a document the planted read-along contains, or the reader opens at page one. */
    @Test
    fun `the saved position points into the archive make-readalong-fixture writes`() {
        val readalong = assertNotNullAndGet(books.firstOrNull { it.uuid == FixtureLibrary.READALONG_UUID })
        assertEquals("OEBPS/ch01.xhtml", readalong.position?.locator?.href)
    }

    @Test
    fun `one book carries a subtitle and the rest send none`() {
        assertEquals(1, books.count { it.displaySubtitle != null })
    }

    private fun <T : Any> assertNotNullAndGet(value: T?): T {
        assertNotNull(value)
        return value!!
    }
}
