package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The reading themes keep their polarity whatever the system is doing. Ported
 * from the theme half of IssaUI's `PaletteTests.swift`; the half about the
 * adaptive palette is in `:ui`'s `PaletteTest`.
 */
class ReaderThemeTest {
    private fun luminance(color: Rgba) = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue

    /** A light theme that has gone dark reads as white-on-white in the renderer, which draws nothing at all. */
    @Test
    fun `the light themes stay light and the dark ones stay dark`() {
        for (theme in ReaderTheme.entries) {
            val background = luminance(theme.background)
            val text = luminance(theme.text)
            if (theme.isDark) {
                assertTrue("$theme should have a dark page", background < 0.3)
                assertTrue("$theme needs light text on its dark page", text > background)
            } else {
                assertTrue("$theme should have a light page", background > 0.7)
                assertTrue("$theme needs dark text on its light page", text < background)
            }
        }
    }

    /** It stands in for the reader's choice: offering it would store it, and Swift can't read it. */
    @Test
    fun `E-Ink's page is never one of the page colours on offer`() {
        assertFalse(ReaderTheme.EINK in ReaderTheme.offered)
        assertEquals(ReaderTheme.entries.size - 1, ReaderTheme.offered.size)
        assertEquals(listOf("paper", "sepia", "night", "slate"), ReaderTheme.offered.map { it.rawValue })
    }

    @Test
    fun `E-Ink's page has one ink, and one grey for text`() {
        val theme = ReaderTheme.EINK
        assertEquals(Rgba.hex(0xFFFFFF), theme.background)
        assertEquals(Rgba.hex(0x000000), theme.text)
        assertEquals("a faint ink is a dithered grey", theme.text, theme.textSecondary)
        assertEquals(theme.text, theme.ink(0.55))
        assertEquals(theme.background, theme.ground(0.94))
        assertEquals(Rgba.hex(0x595959), theme.textTertiary)
        assertFalse(theme.isDark)
    }

    @Test
    fun `the other pages' quiet inks are what they always were`() {
        for (theme in ReaderTheme.offered) {
            assertFalse(theme.isEInk)
            assertEquals(theme.text.withAlpha(0.55), theme.ink(0.55))
            assertEquals(theme.text.withAlpha(0.55), theme.textTertiary)
            assertEquals(theme.text.withAlpha(0.75), theme.textSecondary)
            assertEquals(theme.background.withAlpha(0.94), theme.ground(0.94))
        }
    }

    @Test
    fun `a page's bars can be E-Ink's taller ones, and take that from the page`() {
        val usual = ReaderChrome(59.0, 34.0, 24.0)
        val eink = ReaderChrome(59.0, 34.0, 24.0, barHeight = ReaderChrome.EINK_BAR_HEIGHT)
        assertEquals(59.0 + 48.0, eink.topReserve, 0.0)
        assertEquals(34.0 + 48.0 + 24.0, eink.bottomReserve, 0.0)
        assertEquals(usual.pageSize(402.0, 874.0).height - 8.0, eink.pageSize(402.0, 874.0).height, 0.0)
        assertNotEquals(usual, eink)
    }

    @Test
    fun `filling the screen gives the page both bars' bands, less the margin the top now spends`() {
        val usual = ReaderChrome(59.0, 34.0, 24.0)
        val fills = ReaderChrome(59.0, 34.0, 24.0, fillsScreen = true)
        val bar = ReaderChrome.BAR_HEIGHT
        // Two bars, less the 24 the page's top margin takes back from the top band.
        assertEquals(usual.pageSize(402.0, 874.0).height + 2 * bar - 24.0, fills.pageSize(402.0, 874.0).height, 0.0)
        assertEquals(59.0 + 24.0, fills.topReserve, 0.0)
        assertEquals(34.0 + 24.0, fills.bottomReserve, 0.0)
        assertNotEquals(usual, fills)
        val eink = ReaderChrome(59.0, 34.0, 24.0, barHeight = ReaderChrome.EINK_BAR_HEIGHT, fillsScreen = true)
        val einkUsual = ReaderChrome(59.0, 34.0, 24.0, barHeight = ReaderChrome.EINK_BAR_HEIGHT)
        assertEquals(einkUsual.pageSize(402.0, 874.0).height + 96.0 - 24.0, eink.pageSize(402.0, 874.0).height, 0.0)
    }

    @Test
    fun `where no top bar of its own stands, filling the screen gives back only the footer's band`() {
        val usual = ReaderChrome(52.0, 14.0, 24.0, drawsOwnTopBar = false)
        val fills = ReaderChrome(52.0, 14.0, 24.0, drawsOwnTopBar = false, fillsScreen = true)
        assertEquals(usual.pageSize(402.0, 874.0).height + ReaderChrome.BAR_HEIGHT, fills.pageSize(402.0, 874.0).height, 0.0)
    }
}
