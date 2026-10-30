package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * When the reader prints the book's title under the footer: the setting, the
 * chrome, gestural navigation and a band tall enough to hold it. The Android
 * counterpart of `bandFitsBookTitle` in `BookTitleSettingTests.swift`.
 */
class BookTitleBandTest {
    private fun shows(
        setting: Boolean = true,
        chrome: Boolean = true,
        navBar: Double = 48.0,
        tappable: Double = 0.0,
    ) = ReaderChrome.showsBookTitle(setting, chrome, navBar, tappable)

    @Test
    fun `a gesture bar of the usual height has no room above its handle`() {
        // The handle is drawn across the middle of the band; a title in a 24
        // dp band was drawn through it.
        assertFalse(shows(navBar = 24.0))
        assertTrue(shows(navBar = 48.0))
    }

    @Test
    fun `the setting off draws nothing`() = assertFalse(shows(setting = false))

    @Test
    fun `the chrome away draws nothing`() = assertFalse(shows(chrome = false))

    @Test
    fun `three-button navigation never gets a title, however tall its bar`() {
        assertFalse(shows(navBar = 48.0, tappable = 48.0))
        assertFalse(shows(navBar = 48.0, tappable = 0.5))
    }

    @Test
    fun `no navigation bar at all has no band`() = assertFalse(shows(navBar = 0.0))

    @Test
    fun `a band must be at least 34 dp`() {
        assertEquals(34.0, ReaderChrome.BOOK_TITLE_BAND_MINIMUM, 0.0)
        assertFalse(shows(navBar = ReaderChrome.BOOK_TITLE_BAND_MINIMUM - 0.5))
        assertTrue(shows(navBar = ReaderChrome.BOOK_TITLE_BAND_MINIMUM))
    }
}
