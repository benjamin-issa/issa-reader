package com.benjaminissa.issareader.core.store

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Search splits a query into words on whitespace of every kind. The pattern
 * has no inline flags, which Android's regex engine does not read the way the
 * JVM does; the same splitting is checked on a device by
 * `SearchPatternTest` in the app's instrumented tests.
 */
class SearchSplitTest {
    private fun split(query: String) = query.trim().split(LibraryStore.WHITESPACE)

    @Test
    fun `ordinary spaces, tabs and newlines split`() {
        assertEquals(listOf("tolkien", "100%", "ring"), split("tolkien  100%\tring\n"))
    }

    @Test
    fun `a pasted non-breaking space splits`() {
        assertEquals(listOf("Pure", "100%"), split("Pure 100%"))
        assertEquals(listOf("a", "b"), split("a b"))
    }

    @Test
    fun `other Unicode spaces split`() {
        assertEquals(listOf("a", "b", "c", "d"), split("a b　c d"))
        assertEquals(listOf("a", "b"), split("a\u0085b"))
    }

    @Test
    fun `letters and punctuation do not`() {
        assertEquals(listOf("o'brien_x%"), split("o'brien_x%"))
    }
}
