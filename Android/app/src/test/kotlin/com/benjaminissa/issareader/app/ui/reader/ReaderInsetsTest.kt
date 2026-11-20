package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsCompat.Type
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Where the reader's page begins and ends on a phone. The Android half of
 * `ReaderInsetsTests.swift`, whose cases are all about the Mac's toolbar and
 * are listed in PORTING.md as not ported; what is tested here is the rule
 * that replaced the iPhone's sampled safe area — the edges are read ignoring
 * whether the bars are showing, so the chrome hiding them cannot move the
 * page.
 */
@RunWith(RobolectricTestRunner::class)
class ReaderInsetsTest {
    private fun insets(
        status: Int,
        navigation: Int,
        cutout: Int = 0,
        barsVisible: Boolean = true,
    ): WindowInsetsCompat {
        val builder = WindowInsetsCompat.Builder()
            .setInsetsIgnoringVisibility(Type.statusBars(), Insets.of(0, status, 0, 0))
            .setInsetsIgnoringVisibility(Type.navigationBars(), Insets.of(0, 0, 0, navigation))
            .setInsets(Type.displayCutout(), Insets.of(0, cutout, 0, 0))
        if (barsVisible) {
            builder.setInsets(Type.statusBars(), Insets.of(0, status, 0, 0))
            builder.setInsets(Type.navigationBars(), Insets.of(0, 0, 0, navigation))
        } else {
            builder.setInsets(Type.statusBars(), Insets.NONE)
            builder.setInsets(Type.navigationBars(), Insets.NONE)
        }
        builder.setVisible(Type.statusBars(), barsVisible)
        builder.setVisible(Type.navigationBars(), barsVisible)
        return builder.build()
    }

    @Test
    fun `hiding the bars with the chrome does not move the page`() {
        val shown = ReaderInsets.edges(insets(status = 96, navigation = 72), density = 2f)
        val hidden = ReaderInsets.edges(insets(status = 96, navigation = 72, barsVisible = false), density = 2f)
        assertEquals(ReaderInsets.Edges(48.dp, 36.dp), shown)
        assertEquals("the page is laid out against the bars as they are when shown", shown, hidden)
    }

    @Test
    fun `a camera cutout reaching below the status bar is kept clear`() {
        // A punch-hole that the status bar does not cover: the first line
        // must not sit beside the camera.
        val edges = ReaderInsets.edges(insets(status = 96, navigation = 72, cutout = 130), density = 2f)
        assertEquals(65.dp, edges.top)
    }

    @Test
    fun `a window with no bars reserves nothing`() {
        assertEquals(ReaderInsets.Edges.ZERO, ReaderInsets.edges(WindowInsetsCompat.Builder().build(), density = 2.625f))
    }

    @Test
    fun `the edges are in dp, whatever the screen's density`() {
        val edges = ReaderInsets.edges(insets(status = 126, navigation = 63), density = 2.625f)
        assertEquals(48f, edges.top.value, 0.001f)
        assertEquals(24f, edges.bottom.value, 0.001f)
    }

    /** A punch hole 40 dp down the top edge, a 24 dp gesture bar and the bars as they are when shown. */
    private fun phone(
        cutoutBottomPx: Int = 0,
        navigationPx: Int = 48,
        tappablePx: Int = 0,
        status: Int = 104,
    ): WindowInsetsCompat {
        val builder = WindowInsetsCompat.Builder()
            .setInsetsIgnoringVisibility(Type.statusBars(), Insets.of(0, status, 0, 0))
            .setInsetsIgnoringVisibility(Type.navigationBars(), Insets.of(0, 0, 0, navigationPx))
            .setInsetsIgnoringVisibility(Type.tappableElement(), Insets.of(0, 0, 0, tappablePx))
            .setInsets(Type.displayCutout(), Insets.of(0, cutoutBottomPx, 0, 0))
        if (cutoutBottomPx > 0) {
            builder.setDisplayCutout(
                androidx.core.view.DisplayCutoutCompat(
                    android.graphics.Rect(0, cutoutBottomPx, 0, 0),
                    listOf(android.graphics.Rect(400, 0, 480, cutoutBottomPx)),
                ),
            )
        }
        return builder.build()
    }

    @Test
    fun `a gesture phone with a punch hole may reach to the sensor and the handle`() {
        val edges = ReaderInsets.edges(phone(cutoutBottomPx = 80, navigationPx = 48), density = 2f, cornerRadiusDp = 48.0)
        val fill = edges.fill!!
        assertEquals("the cutout's bottom, plus air", 40.0 + ReaderInsets.SENSOR_AIR, fill.sensorClearance, 0.001)
        assertEquals("half the 24 dp bar, plus air", 12.0 + ReaderInsets.HANDLE_AIR, fill.indicatorClearance, 0.001)
        assertEquals(48.0, fill.cornerRadius, 0.0)
        assertEquals("the edges themselves are unchanged", 52.dp, edges.top)
        assertEquals(24.dp, edges.bottom)
    }

    /** A window whose cutout holds the given rects, with a 52 dp status bar and a 24 dp gesture bar at density 2. */
    private fun withHoles(vararg holes: android.graphics.Rect): WindowInsetsCompat =
        WindowInsetsCompat.Builder()
            .setInsetsIgnoringVisibility(Type.statusBars(), Insets.of(0, 104, 0, 0))
            .setInsetsIgnoringVisibility(Type.navigationBars(), Insets.of(0, 0, 0, 48))
            .setInsets(Type.displayCutout(), Insets.of(0, 99, 0, 0))
            .setDisplayCutout(androidx.core.view.DisplayCutoutCompat(android.graphics.Rect(0, 99, 0, 0), holes.toList()))
            .build()

    @Test
    fun `a punch hole set below the top edge still clears the first line, and a bottom cutout does not`() {
        val hole = android.graphics.Rect(507, 33, 573, 99)
        val bottom = android.graphics.Rect(400, 2300, 480, 2400)
        val fill = ReaderInsets.edges(withHoles(hole), density = 2f, cornerRadiusDp = 48.0).fill!!
        assertEquals("the hole's bottom, plus air", 49.5 + ReaderInsets.SENSOR_AIR, fill.sensorClearance, 0.001)
        val onlyBottom = ReaderInsets.edges(withHoles(bottom), density = 2f, cornerRadiusDp = 48.0).fill!!
        assertEquals("a bottom cutout alone clears nothing at the top", 0.0, onlyBottom.sensorClearance, 0.0)
    }

    @Test
    fun `three-button navigation is not reclaimed`() {
        val fill = ReaderInsets.edges(phone(navigationPx = 96, tappablePx = 96), density = 2f, cornerRadiusDp = 40.0).fill!!
        assertEquals(48.0, fill.indicatorClearance, 0.001)
    }

    @Test
    fun `no navigation bar and no cutout clear nothing`() {
        val fill = ReaderInsets.edges(phone(navigationPx = 0), density = 2f, cornerRadiusDp = 0.0).fill!!
        assertEquals(0.0, fill.sensorClearance, 0.0)
        assertEquals(0.0, fill.indicatorClearance, 0.0)
    }

    @Test
    fun `without a corner radius, as on a tablet, a phone on its side or Android 11, there are no fill edges`() {
        assertNull(ReaderInsets.edges(phone(cutoutBottomPx = 80), density = 2f).fill)
    }

    @Test
    fun `the view reads no corners before Android 12 and so reclaims nothing`() {
        val view = android.view.View(org.robolectric.RuntimeEnvironment.getApplication())
        // No window is attached, so there are no root insets: nothing, as before.
        assertEquals(ReaderInsets.Edges.ZERO, ReaderInsets.current(view))
    }
}
