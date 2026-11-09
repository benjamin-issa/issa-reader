package com.benjaminissa.issareader.ui

import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp
import org.junit.Assert.assertEquals
import org.junit.Test

/** The phone's ramp and spacing, as the Swift `TypographyTests` pin them. */
class TypographyTest {
    @Test
    fun `every named size is the canvas's`() {
        assertEquals(34.sp, Typography.displayLarge.fontSize)
        assertEquals(FontWeight.Medium, Typography.displayLarge.fontWeight)
        assertEquals(28.sp, Typography.display.fontSize)
        assertEquals(22.sp, Typography.title.fontSize)
        assertEquals(17.sp, Typography.bookTitle.fontSize)
        assertEquals(17.sp, Typography.headline.fontSize)
        assertEquals(FontWeight.SemiBold, Typography.headline.fontWeight)
        assertEquals(15.sp, Typography.body.fontSize)
        assertEquals(14.sp, Typography.callout.fontSize)
        assertEquals(13.sp, Typography.subhead.fontSize)
        assertEquals(12.sp, Typography.footnote.fontSize)
        assertEquals(11.sp, Typography.caption.fontSize)
        assertEquals(11.sp, Typography.overline.fontSize)
        assertEquals(FontWeight.SemiBold, Typography.overline.fontWeight)
        assertEquals(1.6.sp, Typography.overline.letterSpacing)
    }

    @Test
    fun `the spacing scale is the canvas's`() {
        assertEquals(4f, Metrics.spacing4.value)
        assertEquals(16f, Metrics.spacing16.value)
        assertEquals(32f, Metrics.spacing32.value)
        assertEquals(48f, Metrics.spacing48.value)
        assertEquals(14f, Metrics.radiusLarge.value)
        assertEquals(16f, Metrics.screenMargin.value)
    }
}
