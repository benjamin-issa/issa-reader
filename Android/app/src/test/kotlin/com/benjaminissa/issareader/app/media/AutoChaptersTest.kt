package com.benjaminissa.issareader.app.media

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Which of the queue's rows is the one being read. Ported from
 * `CarPlayChaptersTests`.
 *
 * The rows are one per nav point, and a Gutenberg-style book packs four
 * chapters into each file, told apart only by fragment. Matching the reader's
 * spine index marked the file's first chapter whichever of the four was being
 * narrated.
 */
class AutoChaptersTest {
    /**
     * Two files: the first holds chapters 1–4 at fragments laid out at 0,
     * 1000, 2000 and 3000; the second is one chapter on its own.
     */
    private val entries = listOf(
        AutoChapters.Entry(spineIndex = 2, fragment = "ch1", title = "Chapter 1"),
        AutoChapters.Entry(spineIndex = 2, fragment = "ch2", title = "Chapter 2"),
        AutoChapters.Entry(spineIndex = 2, fragment = "ch3", title = "Chapter 3"),
        AutoChapters.Entry(spineIndex = 2, fragment = "ch4", title = "Chapter 4"),
        AutoChapters.Entry(spineIndex = 3, fragment = null, title = "Chapter 5"),
    )
    private val laidOut = mapOf("ch1" to 0, "ch2" to 1000, "ch3" to 2000, "ch4" to 3000)

    private fun current(spine: Int, offset: Int, layout: Map<String, Int> = laidOut): Int? =
        AutoChapters.currentIndex(entries, spineIndex = spine, offset = offset) { layout[it] }

    /** The third chapter of a four-chapter file is the third row, not the first. */
    @Test
    fun chapterWithinAFile() {
        assertEquals(2, current(spine = 2, offset = 2400))
        assertEquals("a page that starts on a chapter is that chapter's", 3, current(spine = 2, offset = 3000))
        assertEquals(0, current(spine = 2, offset = 999))
    }

    /** A file of its own is its own row. */
    @Test
    fun wholeFile() {
        assertEquals(4, current(spine = 3, offset = 50_000))
    }

    /** A file that is not laid out, or a spine item with no row, falls back sensibly. */
    @Test
    fun fallbacks() {
        assertEquals(
            "with nothing to compare against, the file's first row is the best answer",
            0,
            current(spine = 2, offset = 2400, layout = emptyMap()),
        )
        assertNull("a spine item no row names has no current row", current(spine = 7, offset = 0))
    }
}
