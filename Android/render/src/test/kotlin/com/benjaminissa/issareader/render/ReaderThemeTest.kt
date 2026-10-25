package com.benjaminissa.issareader.render

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
}
