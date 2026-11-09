package com.benjaminissa.issareader.playback

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

// Ported from `PlaybackTests.swift` (`ChapterNamingTests`).

/**
 * What counts as a chapter name.
 *
 * A read-along coordinator has no table of contents — only the text document
 * the current sentence lives in — so asking it for "the chapter" hands back an
 * archive path. The player sheet knew to hide that; the mini bar did not, and
 * printed `OEBPS/8960978148133687104_chapter_11.xhtml` under the book's title
 * where the chapter name belongs.
 */
class ChapterNamingTest {
    /** A document href is not a chapter name. */
    @Test
    fun rejectsHrefs() {
        for (candidate in listOf(
            "OEBPS/8960978148133687104_chapter_11.xhtml",
            "OEBPS/ch01.xhtml",
            "chapter_11.xhtml",
            "text/part1.html",
            "content.xml",
            "",
            "   ",
        )) {
            assertFalse(candidate, ChapterNaming.isDisplayable(candidate))
        }
    }

    /** A name somebody wrote is a chapter name. */
    @Test
    fun acceptsNames() {
        for (candidate in listOf(
            "The Flight",
            "Chapter 11",
            "17. The When Wendy Grew Up",
            "Peter Breaks Through",
            "Épilogue",
        )) {
            assertTrue(candidate, ChapterNaming.isDisplayable(candidate))
        }
    }
}
