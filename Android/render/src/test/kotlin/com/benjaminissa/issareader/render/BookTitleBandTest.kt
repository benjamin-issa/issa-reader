package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.render.ReaderChrome.BookTitlePlacement
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Where the reader prints the book's title under the footer: in the navigation
 * band where it fits, in a row of its own where it does not, and nowhere with
 * the setting off. The Android counterpart of `bandFitsBookTitle` in
 * `BookTitleSettingTests.swift`, which has only the band: an iPhone's always
 * holds it.
 */
class BookTitleBandTest {
    private fun placement(
        shows: Boolean = true,
        navBar: Double = 48.0,
        tappable: Double = 0.0,
    ) = ReaderChrome.bookTitlePlacement(shows, navBar, tappable)

    @Test
    fun `a gesture bar tall enough to clear its handle holds the title`() {
        assertEquals(BookTitlePlacement.BAND, placement(navBar = 48.0))
        assertEquals(BookTitlePlacement.BAND, placement(navBar = ReaderChrome.BOOK_TITLE_BAND_MINIMUM))
    }

    @Test
    fun `the usual gesture bar gives the title a row of its own`() {
        // The handle is drawn across the middle of the band; a title in a 24
        // dp band was drawn through it.
        assertEquals(BookTitlePlacement.ROW, placement(navBar = 24.0))
        assertEquals(BookTitlePlacement.ROW, placement(navBar = ReaderChrome.BOOK_TITLE_BAND_MINIMUM - 0.5))
    }

    @Test
    fun `three-button navigation gives it a row, however tall its bar`() {
        assertEquals(BookTitlePlacement.ROW, placement(navBar = 48.0, tappable = 48.0))
        assertEquals(BookTitlePlacement.ROW, placement(navBar = 48.0, tappable = 0.5))
    }

    /** A Boox Palma: no navigation bar, so nowhere but a row. It drew no title at all until it had one. */
    @Test
    fun `no navigation bar at all gives it a row`() =
        assertEquals(BookTitlePlacement.ROW, placement(navBar = 0.0))

    @Test
    fun `the setting off, or a tablet, draws nothing anywhere`() {
        assertEquals(BookTitlePlacement.NONE, placement(shows = false, navBar = 48.0))
        assertEquals(BookTitlePlacement.NONE, placement(shows = false, navBar = 0.0))
    }

    @Test
    fun `the band must be at least 34 dp, and a row is 16`() {
        assertEquals(34.0, ReaderChrome.BOOK_TITLE_BAND_MINIMUM, 0.0)
        assertEquals(16.0, ReaderChrome.BOOK_TITLE_ROW, 0.0)
    }

    /** The row comes out of the page, as the bottom edge it is added to: the footer moves up by it, the text with it. */
    @Test
    fun `a title row takes its height from the page`() {
        val without = ReaderChrome(safeAreaTop = 24.0, safeAreaBottom = 0.0, margin = 24.0)
        val with = ReaderChrome(safeAreaTop = 24.0, safeAreaBottom = ReaderChrome.BOOK_TITLE_ROW, margin = 24.0)
        val lost = without.pageSize(402.0, 874.0).height - with.pageSize(402.0, 874.0).height
        assertEquals(ReaderChrome.BOOK_TITLE_ROW, lost, 0.0)
    }
}
