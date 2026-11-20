package com.benjaminissa.issareader.render

import org.junit.Assert.assertEquals
import org.junit.Test

class ImageAttachmentTest {
    /** 800 x 3000, parsed for a 320 x 600 page, is 160 x 600. */
    @Test
    fun `a tall plate is fitted to the page it was parsed for`() {
        val size = ImageAttachment.displaySize(800.0, 3000.0, 320.0, 600.0)
        assertEquals(160.0, size.width, 1e-9)
        assertEquals(600.0, size.height, 1e-9)
    }

    /** The page turns onto its side, 600 x 320: the plate has to fit that page too. */
    @Test
    fun `the same plate on a landscape page is fitted to its height, keeping its proportions`() {
        val size = ImageAttachment.bounds(160.0, 600.0, 600.0, 320.0)
        assertEquals(320.0, size.height, 1e-9)
        assertEquals(160.0 * 320.0 / 600.0, size.width, 1e-9)
        assertEquals(160.0 / 600.0, size.width / size.height, 1e-9)
    }

    @Test
    fun `a plate that already fits is left alone, and never scaled up`() {
        val size = ImageAttachment.bounds(100.0, 80.0, 600.0, 320.0)
        assertEquals(100.0, size.width, 0.0)
        assertEquals(80.0, size.height, 0.0)
    }

    @Test
    fun `the width bound still applies`() {
        val size = ImageAttachment.bounds(400.0, 100.0, 200.0, 600.0)
        assertEquals(200.0, size.width, 1e-9)
        assertEquals(50.0, size.height, 1e-9)
    }

    @Test
    fun `whichever bound is tighter wins`() {
        val size = ImageAttachment.bounds(400.0, 400.0, 300.0, 200.0)
        assertEquals(200.0, size.width, 1e-9)
        assertEquals(200.0, size.height, 1e-9)
    }

    @Test
    fun `an unmeasured page leaves the plate as it is`() {
        val size = ImageAttachment.bounds(160.0, 600.0, 0.0, 0.0)
        assertEquals(160.0, size.width, 0.0)
        assertEquals(600.0, size.height, 0.0)
    }
}
