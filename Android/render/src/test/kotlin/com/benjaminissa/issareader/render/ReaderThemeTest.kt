package com.benjaminissa.issareader.render

import kotlin.math.sqrt
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

    private val punchHole = ReaderChrome.FillEdges(sensorClearance = 44.0, indicatorClearance = 18.0, cornerRadius = 48.0)

    @Test
    fun `a vertical margin sets the filled page's top and bottom and leaves the sides alone`() {
        val none = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, verticalMargin = 0.0)
        val wide = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, verticalMargin = 64.0)
        assertEquals(52.0, none.topReserve, 0.0)
        assertEquals(24.0, none.bottomReserve, 0.0)
        assertEquals(52.0 + 64.0, wide.topReserve, 0.0)
        assertEquals(24.0 + 64.0, wide.bottomReserve, 0.0)
        assertEquals(402.0 - 32.0, wide.pageSize(402.0, 874.0).width, 0.0)
        assertEquals(16.0, ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true).verticalMargin, 0.0)
        assertNotEquals(none, wide)
    }

    @Test
    fun `without filling the vertical margin and the edges are not read`() {
        val usual = ReaderChrome(52.0, 24.0, 16.0)
        val same = ReaderChrome(52.0, 24.0, 16.0, verticalMargin = 60.0, fillEdges = punchHole)
        assertEquals(usual.topReserve, same.topReserve, 0.0)
        assertEquals(usual.bottomReserve, same.bottomReserve, 0.0)
    }

    @Test
    fun `a gesture phone with a punch hole lets the text reach part way into both edges`() {
        val whole = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true)
        val part = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, fillEdges = punchHole)
        // 48 - sqrt(48^2 - 32^2): the depth at which the corner cuts in no more than the 16 side margin.
        val depth = 48.0 - sqrt(48.0 * 48.0 - 32.0 * 32.0)
        assertEquals(12.2, depth, 0.05)
        assertEquals(44.0, part.clearTop, 0.0)
        assertEquals(44.0 + 16.0, part.topReserve, 0.0)
        assertEquals(18.0, part.clearBottom, 0.0)
        assertEquals(18.0 + 16.0, part.bottomReserve, 0.0)
        assertEquals(whole.pageSize(402.0, 874.0).height + 8.0 + 6.0, part.pageSize(402.0, 874.0).height, 0.0)
    }

    @Test
    fun `three-button navigation keeps its whole band`() {
        val edges = ReaderChrome.FillEdges(sensorClearance = 0.0, indicatorClearance = 48.0, cornerRadius = 0.0)
        val chrome = ReaderChrome(24.0, 48.0, 16.0, fillsScreen = true, fillEdges = edges)
        assertEquals(48.0 + 16.0, chrome.bottomReserve, 0.0)
    }

    @Test
    fun `no navigation bar and no cutout, as on a Boox phone, reclaims all there was and no more`() {
        val edges = ReaderChrome.FillEdges(sensorClearance = 0.0, indicatorClearance = 0.0, cornerRadius = 0.0)
        val chrome = ReaderChrome(24.0, 0.0, 16.0, fillsScreen = true, fillEdges = edges)
        assertEquals(0.0 + 16.0, chrome.topReserve, 0.0)
        assertEquals(16.0, chrome.bottomReserve, 0.0)
    }

    @Test
    fun `a round corner keeps the text down until it clears the side margin`() {
        val edges = ReaderChrome.FillEdges(sensorClearance = 0.0, indicatorClearance = 0.0, cornerRadius = 48.0)
        val chrome = ReaderChrome(52.0, 34.0, 16.0, fillsScreen = true, fillEdges = edges)
        assertEquals(edges.cornerDepth(16.0), chrome.clearTop, 0.0)
        assertEquals(0.0, edges.cornerDepth(48.0), 0.0)
        assertEquals(0.0, edges.cornerDepth(60.0), 0.0)
        assertEquals(48.0, edges.cornerDepth(0.0), 1e-9)
    }

    @Test
    fun `the edges never take more than the edge there is`() {
        val edges = ReaderChrome.FillEdges(sensorClearance = 80.0, indicatorClearance = 60.0, cornerRadius = 48.0)
        val chrome = ReaderChrome(30.0, 20.0, 16.0, fillsScreen = true, fillEdges = edges)
        assertEquals(30.0, chrome.clearTop, 0.0)
        assertEquals(20.0, chrome.clearBottom, 0.0)
    }

    @Test
    fun `the filled reserves are values of the window, not of whether the chrome shows`() {
        // The chrome has no visibility input at all: equal windows give equal reserves.
        val a = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, verticalMargin = 20.0, fillEdges = punchHole)
        val b = ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, verticalMargin = 20.0, fillEdges = punchHole)
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertNotEquals(a, ReaderChrome(52.0, 24.0, 16.0, fillsScreen = true, verticalMargin = 20.0))
    }
}
