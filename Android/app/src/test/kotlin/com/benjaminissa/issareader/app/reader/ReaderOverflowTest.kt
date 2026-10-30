package com.benjaminissa.issareader.app.reader

import com.benjaminissa.issareader.app.reader.ReaderOverflow.Row
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * The reader's top bar never opens a menu of one row.
 *
 * A one-row menu is a see-through pill over the tools beside the button on
 * the iPhone, and Android keeps the same shape so the two bars agree. The
 * first 1.5.2 build did it whenever no sentence was lit: Find and Marks had
 * moved into the bar, Stop Narration hid itself, and Contents was left alone
 * in the menu. Ported from `ReaderOverflowTests.swift`.
 */
class ReaderOverflowTest {
    private data class Combination(val foldsFind: Boolean, val foldsMarks: Boolean, val hasNarration: Boolean)

    private val combinations = listOf(false, true).flatMap { find ->
        listOf(false, true).flatMap { marks ->
            listOf(false, true).map { Combination(find, marks, it) }
        }
    }

    private fun of(c: Combination) = ReaderOverflow.of(c.foldsFind, c.foldsMarks, c.hasNarration)

    /** No combination makes a menu of one row. */
    @Test
    fun neverOneRow() {
        assertEquals(8, combinations.size)
        for (c in combinations) {
            val overflow = of(c)
            if (overflow is ReaderOverflow.Menu) {
                assertTrue("a one-row menu for $c", overflow.rows.size >= 2)
            }
        }
    }

    /** A narrated book's menu always lists Contents, then Stop Narration. */
    @Test
    fun narratedBookKeepsTheMenu() {
        for (c in combinations.filter { it.hasNarration }) {
            val overflow = of(c)
            if (overflow !is ReaderOverflow.Menu) {
                fail("no menu for $c")
                continue
            }
            assertEquals(listOf(Row.CONTENTS, Row.STOP_NARRATION), overflow.rows.takeLast(2))
        }
        // On a phone nothing is folded, and that menu is exactly the two.
        assertEquals(
            ReaderOverflow.Menu(listOf(Row.CONTENTS, Row.STOP_NARRATION)),
            ReaderOverflow.of(foldsFind = false, foldsMarks = false, hasNarration = true),
        )
    }

    /** A book with nothing to narrate and nothing folded has a Contents button. */
    @Test
    fun plainBookHasContentsButton() {
        assertEquals(
            ReaderOverflow.ContentsButton,
            ReaderOverflow.of(foldsFind = false, foldsMarks = false, hasNarration = false),
        )
    }

    /** Folded tools come first, in the bar's order. */
    @Test
    fun foldedToolsComeFirst() {
        assertEquals(
            ReaderOverflow.Menu(listOf(Row.FIND, Row.CONTENTS)),
            ReaderOverflow.of(foldsFind = true, foldsMarks = false, hasNarration = false),
        )
        assertEquals(
            ReaderOverflow.Menu(listOf(Row.FIND, Row.MARKS, Row.CONTENTS, Row.STOP_NARRATION)),
            ReaderOverflow.of(foldsFind = true, foldsMarks = true, hasNarration = true),
        )
    }

    // TopBarFit: what the window can hold, which is what feeds the above

    /** A 360 dp phone fits everything, with the Ask sparkle showing. */
    @Test
    fun aPhoneFitsEverything() {
        for (width in listOf(360f, 375f, 412f, 440f)) {
            val fit = TopBarFit.fitting(width, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING)
            assertEquals("at $width dp", TopBarFit.FULL, fit)
            assertTrue(fit.showsFind && fit.showsMarks)
        }
        assertEquals(TopBarFit.FULL, TopBarFit.fitting(360f, showsAsk = false, glyphDp = GLYPH, paddingDp = PADDING))
    }

    /** A narrow window folds Find first, then Marks. */
    @Test
    fun aNarrowWindowFoldsFindThenMarks() {
        // Room for one square more than the always-present five, not two.
        val findFolded = TopBarFit.fitting(260f, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING)
        assertEquals(TopBarFit.FIND_IN_MENU, findFolded)
        assertTrue(!findFolded.showsFind && findFolded.showsMarks)

        val bothFolded = TopBarFit.fitting(200f, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING)
        assertEquals(TopBarFit.FIND_AND_MARKS_IN_MENU, bothFolded)
        assertTrue(!bothFolded.showsFind && !bothFolded.showsMarks)
    }

    /** Without the sparkle there is a square more room, so the fold comes later. */
    @Test
    fun withoutAskTheFoldComesLater() {
        assertEquals(TopBarFit.FIND_IN_MENU, TopBarFit.fitting(230f, showsAsk = false, glyphDp = GLYPH, paddingDp = PADDING))
        assertEquals(TopBarFit.FIND_AND_MARKS_IN_MENU, TopBarFit.fitting(230f, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING))
    }

    /** What a fit folds is what the menu is handed: the two tests above meet here. */
    @Test
    fun aFitFeedsTheMenu() {
        val fit = TopBarFit.fitting(200f, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING)
        assertEquals(
            ReaderOverflow.Menu(listOf(Row.FIND, Row.MARKS, Row.CONTENTS, Row.STOP_NARRATION)),
            ReaderOverflow.of(foldsFind = !fit.showsFind, foldsMarks = !fit.showsMarks, hasNarration = true),
        )
        val full = TopBarFit.fitting(360f, showsAsk = true, glyphDp = GLYPH, paddingDp = PADDING)
        assertEquals(
            ReaderOverflow.ContentsButton,
            ReaderOverflow.of(foldsFind = !full.showsFind, foldsMarks = !full.showsMarks, hasNarration = false),
        )
    }

    private companion object {
        /** The bar's square, as `ReaderView` passes it. */
        const val GLYPH = 38f
        const val PADDING = 20f
    }
}
