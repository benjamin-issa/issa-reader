package com.benjaminissa.issareader.app.model

import com.benjaminissa.issareader.core.InMemoryKeyValueStore
import com.benjaminissa.issareader.render.ReaderStyle
import com.benjaminissa.issareader.render.ReaderStyleOverride
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The page margin as the reading settings and a book resolve it: a global
 * default that a book can override, like text size and typeface.
 */
class PageMarginOverrideTest {
    private val store = InMemoryKeyValueStore()
    private val settings = PlaybackSettings(store)

    /** What the Aa sheet's `edit` does with a margin change on one book. */
    private fun editBook(uuid: String, margin: Double) {
        settings.setOverride(settings.readerStyle.difference(settings.style(uuid).copy(pageMargin = margin)), uuid)
    }

    @Test
    fun `a book's own margin wins over the default and leaves the others alone`() {
        editBook("middle", 4.0)
        assertEquals(4.0, settings.style("middle").pageMargin, 0.0)
        assertEquals(24.0, settings.style("first").pageMargin, 0.0)
        assertEquals(24.0, settings.style("last").pageMargin, 0.0)
        assertEquals(1, settings.override("middle")!!.count)
    }

    @Test
    fun `a book without a margin of its own follows a later change of default`() {
        editBook("a", 48.0)
        settings.setOverride(ReaderStyleOverride(fontSize = 22.0), "b")
        settings.readerStyle = settings.readerStyle.copy(pageMargin = 12.0)
        assertEquals(12.0, settings.style("b").pageMargin, 0.0)
        assertEquals(12.0, settings.style("never-touched").pageMargin, 0.0)
        assertEquals("a book that took its own margin keeps it", 48.0, settings.style("a").pageMargin, 0.0)
    }

    @Test
    fun `use my defaults clears the margin with the rest`() {
        editBook("a", 4.0)
        settings.setOverride(null, "a")
        assertNull(settings.override("a"))
        assertEquals(24.0, settings.style("a").pageMargin, 0.0)
    }

    @Test
    fun `setting a margin back to the default leaves no override behind`() {
        editBook("a", 4.0)
        editBook("a", 24.0)
        assertNull(settings.override("a"))
    }

    @Test
    fun `a book's margin and the default survive a restart`() {
        editBook("a", 0.0)
        settings.readerStyle = settings.readerStyle.copy(pageMargin = 36.0)
        val reopened = PlaybackSettings(store)
        assertEquals(0.0, reopened.style("a").pageMargin, 0.0)
        assertEquals(36.0, reopened.style("b").pageMargin, 0.0)
        assertEquals(ReaderStyle().copy(pageMargin = 36.0).pageMargin, reopened.readerStyle.pageMargin, 0.0)
    }
}
