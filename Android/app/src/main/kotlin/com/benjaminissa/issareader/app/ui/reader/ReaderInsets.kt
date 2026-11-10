package com.benjaminissa.issareader.app.ui.reader

import android.content.res.Configuration
import android.os.Build
import android.view.RoundedCorner
import android.view.View
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import com.benjaminissa.issareader.app.ui.settings.ReadingSettings
import com.benjaminissa.issareader.render.ReaderChrome

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
    data class Edges(
        val top: Dp,
        val bottom: Dp,
        /**
         * How far a page that fills the screen may reach into those edges,
         * where this window can say; null keeps the page clear of them whole.
         */
        val fill: ReaderChrome.FillEdges? = null,
    ) {
        companion object {
            val ZERO = Edges(0.dp, 0.dp)
        }
    }

    /** What the bars and the cutout take, wherever the bars are now; zero before the window has any. */
    fun current(view: View): Edges {
        val insets = ViewCompat.getRootWindowInsets(view) ?: return Edges.ZERO
        val metrics = view.resources.displayMetrics
        val density = metrics.density
        // Corners are only reported from Android 12, and a phone held upright
        // is the only shape the reclaim is drawn for; elsewhere the page keeps
        // clear of the whole edge, as it always did.
        val config = view.resources.configuration
        val upright = metrics.heightPixels > metrics.widthPixels && config.orientation != Configuration.ORIENTATION_LANDSCAPE
        val phone = ReadingSettings.offersBookTitle(config.smallestScreenWidthDp)
        val radius = if (upright && phone) cornerRadiusPx(insets)?.let { it / (if (density > 0) density else 1f) } else null
        return edges(insets, density, cornerRadiusDp = radius?.toDouble())
    }

    /** The largest of the four screen corners' radii, in pixels; null before Android 12, which does not say. */
    private fun cornerRadiusPx(insets: WindowInsetsCompat): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return null
        val window = insets.toWindowInsets() ?: return null
        return listOf(
            RoundedCorner.POSITION_TOP_LEFT,
            RoundedCorner.POSITION_TOP_RIGHT,
            RoundedCorner.POSITION_BOTTOM_LEFT,
            RoundedCorner.POSITION_BOTTOM_RIGHT,
        ).maxOf { window.getRoundedCorner(it)?.radius ?: 0 }
    }

    /**
     * The rule itself, on any set of insets: the larger of the system bars'
     * and the cutout's reach at each edge, as they are when shown, and never
     * negative.
     *
     * @param density pixels per dp.
     * @param cornerRadiusDp the screen's largest corner radius, or null where
     * the window cannot say or the page may not reach into the edges at all
     * (a tablet, a phone held on its side, Android 11); null means [Edges.fill]
     * is null too.
     */
    fun edges(insets: WindowInsetsCompat, density: Float, cornerRadiusDp: Double? = null): Edges {
        val bars = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.systemBars())
        // A cutout is never hidden, so its live insets are already the ones
        // to keep clear of.
        val cutout = insets.getInsets(WindowInsetsCompat.Type.displayCutout())
        val scale = if (density > 0) density else 1f
        val navBottom = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.navigationBars()).bottom / scale.toDouble()
        val tappableBottom = insets.getInsetsIgnoringVisibility(WindowInsetsCompat.Type.tappableElement()).bottom / scale.toDouble()
        val cutoutBottom = insets.displayCutout?.boundingRects
            // Only what touches the top edge: a notch's side or a bottom cutout is not in the first line's way.
            ?.filter { it.top <= 0 }
            ?.maxOfOrNull { it.bottom }
            ?.let { it / scale.toDouble() } ?: 0.0
        return Edges(
            top = (maxOf(bars.top, cutout.top, 0) / scale).dp,
            bottom = (maxOf(bars.bottom, cutout.bottom, 0) / scale).dp,
            fill = cornerRadiusDp?.let { fillEdges(cutoutBottom, navBottom, tappableBottom, it) },
        )
    }

    /** Air kept between the camera cutout and the first line, in dp. */
    const val SENSOR_AIR = 4.0

    /** Air kept above the gesture handle's reach, in dp. */
    const val HANDLE_AIR = 6.0

    /**
     * How far text may reach into the system areas, from the window's
     * measures, all in dp.
     *
     * The sensor's clearance is the bottom of the cutout plus a little air,
     * or nothing where there is no cutout. The bottom depends on the
     * navigation: a gesture bar holds only its handle, across the middle of
     * the band, so text may come down to just above it; three-button
     * navigation fills its whole band, which is not reclaimed; no bar at all
     * (a Boox phone) has nothing to clear.
     */
    fun fillEdges(cutoutBottomDp: Double, navBottomDp: Double, tappableBottomDp: Double, cornerRadiusDp: Double): ReaderChrome.FillEdges {
        val sensor = if (cutoutBottomDp > 0) cutoutBottomDp + SENSOR_AIR else 0.0
        val indicator = when {
            navBottomDp <= 0.0 -> 0.0
            tappableBottomDp > 0.0 -> navBottomDp
            else -> navBottomDp / 2 + HANDLE_AIR
        }
        return ReaderChrome.FillEdges(sensor, indicator, cornerRadiusDp)
    }
}
