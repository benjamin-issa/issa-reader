package com.benjaminissa.issareader.app.ui.reader

import android.view.View
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat

/**
 * The device's own unsafe edges — the status bar and any camera cutout above,
 * the navigation bar or gesture handle below — as they are with the bars
 * showing.
 *
 * The reader lays its page out against these rather than against the live
 * insets, because the live ones move: hiding the status and navigation bars
 * with the chrome changes them, and anything measured against them
 * re-paginates the chapter. So the edges are read *ignoring visibility* —
 * what the bars take when they are shown, whether or not they are — and held
 * by the screen, re-read only when the window's size really changes (a
 * rotation, a split screen). A chrome toggle cannot reach the page.
 *
 * The Swift file's other half, the Mac's toolbar reserve, has no Android
 * counterpart: a phone or tablet reader draws its own bar over the page.
 */
object ReaderInsets {
    /** The top and bottom the page keeps clear of, in dp. */
    data class Edges(val top: Dp, val bottom: Dp) {
        companion object {
            val ZERO = Edges(0.dp, 0.dp)
        }
    }

    /** What the bars and the cutout take, wherever the bars are now; zero before the window has any. */
    fun current(view: View): Edges {
        val insets = ViewCompat.getRootWindowInsets(view) ?: return Edges.ZERO
        return edges(insets, view.resources.displayMetrics.density)
    }

    /**
     * The rule itself, on any set of insets: the larger of the system bars'
     * and the cutout's reach at each edge, as they are when shown, and never
     * negative.
     *
     * @param density pixels per dp.
     */
    fun edges(insets: WindowInsetsCompat, density: Float): Edges {
        val bars = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.systemBars())
        // A cutout is never hidden, so its live insets are already the ones
        // to keep clear of.
        val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
        val scale = if (density > 0) density else 1f
        return Edges(
            top = (maxOf(bars.top, cutout.top, 0) / scale).dp,
            bottom = (maxOf(bars.bottom, cutout.bottom, 0) / scale).dp,
        )
    }
}
