package com.benjaminissa.issareader.ui

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The palette adapts to the system; the reading themes deliberately do not
 * (that half is `:render`'s `ReaderThemeTest`). Ported from `PaletteTests.swift`.
 */
class PaletteTest {
    @Test
    fun `the palette does follow the system`() {
        assertTrue(IssaColors.Light.paper.luminance() > 0.7f)
        assertTrue(IssaColors.Dark.paper.luminance() < 0.3f)
        assertTrue(IssaColors.Light.ink.luminance() < 0.3f)
        assertTrue(IssaColors.Dark.ink.luminance() > 0.7f)
    }

    @Test
    fun `the tokens are the canvas's values`() {
        assertEquals(hex(0xEFE8DC), IssaColors.Light.paper)
        assertEquals(hex(0x17150F), IssaColors.Dark.paper)
        assertEquals(hex(0xE2853A), IssaColors.Light.tangerine)
        assertEquals(hex(0xEE9B57), IssaColors.Dark.tangerine)
    }

    @Test
    fun `a server colour string is read or refused, never guessed`() {
        assertEquals(Color(0xFF123456), colorFromHexString(" #123456 "))
        assertEquals(Color(0xFFABCDEF), colorFromHexString("abcdef"))
        assertNull(colorFromHexString("#12345"))
        assertNull(colorFromHexString("#GGGGGG"))
        assertNull(colorFromHexString(""))
        assertNull(colorFromHexString(null))
    }
}
