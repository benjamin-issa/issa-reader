package com.benjaminissa.issareader.app.ui.reader

import com.benjaminissa.issareader.epub.EpubPackage
import com.benjaminissa.issareader.testing.Fixtures
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The contents list, built once instead of per rendered row. Ported from
 * `ChapterContentsTests.swift`: what needs pinning is that the rows
 * themselves are unchanged now that the href lookup is a map built once.
 */
class ChapterContentsTest {
    private fun alice(): EpubPackage = EpubPackage.open(Fixtures.epub("alice.epub"))

    /**
     * One row per nav point, not per spine item. Books that pack many
     * chapters into a few large files distinguish them only by fragment.
     */
    @Test
    fun `every navigation point that resolves gets its own row`() {
        val book = alice()
        val hrefs = book.spine.map { it.href }.toSet()
        val expected = book.navigation.filter { it.href in hrefs }
        assertFalse("the fixture has to have navigation for this to test anything", expected.isEmpty())

        val entries = ChapterContents.build(book)
        assertEquals(expected.size, entries.size)
        assertEquals(
            expected.mapIndexed { index, point -> point.title.ifEmpty { "Chapter ${index + 1}" } },
            entries.map { it.title },
        )
        assertEquals(expected.map { it.fragment }, entries.map { it.fragment })
    }

    /** First match wins, and a row pointing at the wrong spine item opens the wrong chapter. */
    @Test
    fun `each row points at the spine item its navigation entry names`() {
        val book = alice()
        for (entry in ChapterContents.build(book)) {
            val href = book.navigation.first { it.fragment == entry.fragment && it.title == entry.title }.href
            val expected = book.spine.indexOfFirst { it.href == href }
            assertEquals("\"${entry.title}\" opens spine item ${entry.spineIndex}, not $expected", expected, entry.spineIndex)
        }
    }

    /** Ids are what the current-chapter marker is matched on, so two rows sharing one would mark both. */
    @Test
    fun `row ids are unique`() {
        val entries = ChapterContents.build(alice())
        assertEquals(entries.size, entries.map { it.id }.toSet().size)
    }

    @Test
    fun `no navigation at all still yields a row per spine item`() {
        val book = alice()
        val entries = ChapterContents.build(book.copy(navigation = emptyList()))
        assertEquals(book.spine.size, entries.size)
        assertEquals(book.spine.indices.toList(), entries.map { it.spineIndex })
        assertTrue(entries.all { it.fragment == null })
    }

    @Test
    fun `no book at all yields no rows`() {
        assertTrue(ChapterContents.build(null).isEmpty())
    }

    /** The marker sits on the row the reader is inside, when one file holds several. */
    @Test
    fun `the current row is the last one whose anchor is on the page`() {
        val rows = listOf(
            ChapterContents.Entry(0, null, "Cover", 0, 0),
            ChapterContents.Entry(1, "one", "One", 0, 1),
            ChapterContents.Entry(1, "two", "Two", 0, 2),
            ChapterContents.Entry(1, "three", "Three", 0, 3),
        )
        assertEquals(2, ChapterContents.currentId(rows, 1) { setOf("one", "two") })
        assertEquals("nothing visible: the file's first row", 1, ChapterContents.currentId(rows, 1) { emptySet() })
        assertEquals("one row for the file: that row, without asking", 0, ChapterContents.currentId(rows, 0) { error("not asked") })
    }
}
