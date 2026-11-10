package com.benjaminissa.issareader.app.ui.reader

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the margin control decides, apart from how it draws: Swift's
 * `MarginControlModel`, `MarginPreview` and `MarginBands`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class MarginControlTest {
    @Test
    fun `the presets are the four the iPhone offers and standard is the real default`() {
        assertEquals(
            listOf("Wide" to 48.0, "Standard" to 24.0, "Narrow" to 12.0, "Edge" to 4.0),
            MarginPreset.entries.map { it.title to it.points },
        )
        assertEquals(com.benjaminissa.issareader.render.ReaderStyle().pageMargin, MarginPreset.STANDARD.points, 0.0)
        assertEquals("typography.margins.edge", MarginPreset.EDGE.tag)
    }

    @Test
    fun `the slider runs from 0 to 64 in steps of 2`() {
        assertEquals(0f..64f, MarginControlModel.sliderRange)
        // Compose counts the stops between the ends: 0, 2, ... 64 is 31 of them.
        assertEquals(31, MarginControlModel.steps)
    }

    @Test
    fun `a stored margin past the track stands at its end and is labelled as stored`() {
        assertEquals(64f, MarginControlModel.sliderValue(100.0), 0f)
        assertEquals("100 pt", MarginControlModel.label(100.0))
        assertEquals("100 points", MarginControlModel.spoken(100.0))
        assertEquals(0f, MarginControlModel.sliderValue(-3.0), 0f)
        assertEquals(24f, MarginControlModel.sliderValue(24.0), 0f)
        assertEquals("24 pt", MarginControlModel.label(24.0))
        assertEquals("0 pt", MarginControlModel.label(0.0))
    }

    @Test
    fun `nothing is rewritten unless the thumb moves`() {
        // The thumb restating where it stands (a stored 100 shows at 64) is not a move.
        assertNull(MarginControlModel.moved(64f, 100.0))
        assertNull(MarginControlModel.moved(24f, 24.0))
        assertEquals(30.0, MarginControlModel.moved(30f, 100.0)!!, 0.0)
        assertEquals(0.0, MarginControlModel.moved(0f, 24.0)!!, 0.0)
    }

    @Test
    fun `a preset is selected only for the margin it stands for`() {
        assertEquals(MarginPreset.EDGE, MarginControlModel.preset(4.0))
        assertEquals(MarginPreset.STANDARD, MarginControlModel.preset(24.2))
        assertNull(MarginControlModel.preset(30.0))
        assertNull(MarginControlModel.preset(100.0))
    }

    @Test
    fun `bands show while dragging and linger after`() = runTest {
        val preview = MarginPreview(this, lingerMillis = 1500)
        assertFalse(preview.isShowing)
        preview.dragging(true)
        assertTrue(preview.isShowing)
        advanceTimeBy(10_000)
        assertTrue("held up for as long as the finger is down", preview.isShowing)
        preview.dragging(false)
        assertTrue("letting go keeps them up", preview.isShowing)
        advanceTimeBy(1499)
        assertTrue(preview.isShowing)
        advanceTimeBy(2)
        assertFalse(preview.isShowing)
    }

    @Test
    fun `a preset tap shows the bands for the linger time and a later change restarts it`() = runTest {
        val preview = MarginPreview(this, lingerMillis = 1500)
        preview.linger()
        assertTrue(preview.isShowing)
        assertFalse(preview.isDragging)
        advanceTimeBy(1000)
        preview.linger()
        advanceTimeBy(1000)
        assertTrue("restarted, so 2 s after the first call is still inside the second's 1.5 s", preview.isShowing)
        advanceTimeBy(501)
        assertFalse(preview.isShowing)
    }

    @Test
    fun `closing the sheet resets the bands and cancels the pending hide`() = runTest {
        val preview = MarginPreview(this, lingerMillis = 1500)
        preview.dragging(true)
        preview.linger()
        preview.reset()
        assertFalse(preview.isShowing)
        assertFalse(preview.isDragging)
        assertFalse(preview.isLingering)
        // A change after the reset starts a fresh linger rather than inheriting the old timer.
        preview.linger()
        advanceTimeBy(1000)
        assertTrue(preview.isShowing)
    }

    @Test
    fun `a page's bands are its margin at each side`() {
        assertEquals(listOf(0f..24f, 378f..402f), MarginBandGeometry.page(402f, 24f))
        assertEquals(listOf(0f..0f, 402f..402f), MarginBandGeometry.page(402f, 0f))
        // Never wider than half the track each, so two wide margins cannot cross.
        assertEquals(listOf(0f..100f, 100f..200f), MarginBandGeometry.page(200f, 150f))
        assertEquals(listOf(0f..0f, 200f..200f), MarginBandGeometry.page(200f, -5f))
    }

    @Test
    fun `the sheet stops halfway only on a phone held upright`() {
        assertTrue(TypographySheet.opensHalfHeight(402, 874))
        assertFalse("on its side", TypographySheet.opensHalfHeight(874, 402))
        assertFalse("a tablet", TypographySheet.opensHalfHeight(800, 1280))
        assertFalse("a small phone on its side", TypographySheet.opensHalfHeight(592, 360))
    }
}
