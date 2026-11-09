package com.benjaminissa.issareader.ui

import androidx.compose.material3.surfaceColorAtElevation
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.unit.dp
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

    /** WCAG's contrast ratio between two colours. */
    private fun contrast(a: Color, b: Color): Float {
        val (light, dark) = listOf(a.luminance(), b.luminance()).sortedDescending()
        return (light + 0.05f) / (dark + 0.05f)
    }

    @Test
    fun `E-Ink mode has no colour in it`() {
        with(IssaColors.EInk) {
            val all = listOf(
                paper, surface, surfaceRaised, border, borderStrong, ink, inkSecondary, inkTertiary, inkQuaternary,
                tangerine, tangerinePressed, moss, slate, alert,
            )
            for (token in all) {
                assertEquals("$token is not a grey", token.red, token.green)
                assertEquals("$token is not a grey", token.green, token.blue)
                assertEquals("$token is not opaque", 1f, token.alpha)
            }
        }
    }

    @Test
    fun `E-Ink mode's contrast is what the design promises`() {
        with(IssaColors.EInk) {
            assertEquals(21f, contrast(ink, paper), 0.01f)
            assertEquals("black, so white on it is a white label", ink, tangerine)
            assertTrue(contrast(Color.White, tangerine) >= 7f)
            assertTrue(contrast(inkTertiary, paper) >= 7f)
            assertTrue(contrast(inkQuaternary, paper) >= 7f)
            assertTrue("drawn for a light page, whatever the system says", !isDark)
            assertTrue(isEInk)
        }
        assertTrue("and only there", !IssaColors.Light.isEInk && !IssaColors.Dark.isEInk)
    }

    /** A raised surface is tinted, and a tint on a panel is a sheet of dithered grey: the player's was. */
    @Test
    fun `nothing raised in E-Ink mode comes out grey`() {
        val scheme = colorScheme(IssaColors.EInk)
        for (elevation in listOf(1, 3, 6, 12)) {
            assertEquals(Color.White, scheme.surfaceColorAtElevation(elevation.dp))
        }
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
