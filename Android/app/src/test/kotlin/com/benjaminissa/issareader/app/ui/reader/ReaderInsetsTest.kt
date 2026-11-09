package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.ui.unit.dp
import androidx.core.graphics.Insets
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsCompat.Type
import org.junit.Assert.assertEquals
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
}
