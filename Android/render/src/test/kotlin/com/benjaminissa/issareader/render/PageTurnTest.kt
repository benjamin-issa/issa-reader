package com.benjaminissa.issareader.render

import com.benjaminissa.issareader.render.PageTurn.Direction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

private fun Double.isClose(other: Double, within: Double = 0.001) = abs(this - other) <= within

/**
 * The rules a turning page follows, each checked against what was measured
 * rather than against what seemed reasonable. Ported from `PageTurnTests.swift`.
 */
class PageTurnTest {
    private val width = 402.0

    // The setting

    @Test
    fun `None is stored as none, and every style has a name`() {
        assertEquals(PageTurnStyle.INSTANT, PageTurnStyle.fromRawValue("none"))
        assertEquals(PageTurnStyle.SLIDE, PageTurnStyle.fromRawValue("slide"))
        assertEquals(PageTurnStyle.COVER, PageTurnStyle.fromRawValue("cover"))
        assertEquals(listOf("Slide", "Cover", "None"), PageTurnStyle.entries.map { it.title })
    }

    @Test
    fun `Reduce Motion turns every page instantly, and nothing else does`() {
        for (style in PageTurnStyle.entries) {
            assertEquals(PageTurnStyle.INSTANT, PageTurn.effectiveStyle(style, reduceMotion = true))
            assertEquals(style, PageTurn.effectiveStyle(style, reduceMotion = false))
        }
    }

    // The 1.4.1 swipe

    /** None keeps the swipe exactly as it was: decided on lift-off, clear of the system's dismiss edge, and only past 24 points. */
    @Test
    fun `None's swipe is 1_4_1's`() {
        assertNull("the dismiss edge", PageTurn.liftOffSwipe(startX = 20.0, translation = -100.0))
        assertEquals(Direction.FORWARD, PageTurn.liftOffSwipe(startX = 21.0, translation = -24.0))
        assertNull(PageTurn.liftOffSwipe(startX = 21.0, translation = -23.0))
        assertEquals(Direction.BACKWARD, PageTurn.liftOffSwipe(startX = 200.0, translation = 30.0))
    }

    // Following the finger

    /**
     * A paging scroll view's page starts to follow after ten points of travel,
     * and then by the travel past those ten, to within a tenth of a point.
     */
    @Test
    fun `the page follows one for one, from ten points in, with no jump`() {
        assertFalse(PageTurn.beginsTracking(startX = 200.0, translation = -9.9))
        assertTrue(PageTurn.beginsTracking(startX = 200.0, translation = -10.0))
        assertFalse("the dismiss edge", PageTurn.beginsTracking(startX = 20.0, translation = -200.0))

        fun offset(translation: Double) =
            PageTurn.trackedOffset(translation = translation, width = width, canGoBack = true, canGoForward = true)
        assertEquals(0.0, offset(-9.0), 0.0)
        assertTrue(offset(-60.3).isClose(-50.3))
        assertTrue(offset(-120.6).isClose(-110.6))
        assertTrue(offset(180.9).isClose(170.9))
        // Continuous across the slop: no jump when it starts to follow.
        assertEquals(0.0, offset(-10.0), 0.0)
        assertTrue(offset(-11.0).isClose(-1.0))
    }

    @Test
    fun `the page does not move past the first or last page of the book`() {
        assertEquals(0.0, PageTurn.trackedOffset(translation = -150.0, width = width, canGoBack = true, canGoForward = false), 0.0)
        assertEquals(0.0, PageTurn.trackedOffset(translation = 150.0, width = width, canGoBack = false, canGoForward = true), 0.0)
        assertEquals(-width, PageTurn.trackedOffset(translation = -2000.0, width = width, canGoBack = true, canGoForward = true), 0.0)
    }

    /** Caught mid-slide, the page carries on from where it was. */
    @Test
    fun `a caught page moves on from where it was caught`() {
        val base = 120.0
        assertEquals(base, PageTurn.trackedOffset(translation = 10.0, base = base, width = width, canGoBack = true, canGoForward = true), 0.0)
        assertTrue(
            PageTurn.trackedOffset(translation = -40.0, base = base, width = width, canGoBack = true, canGoForward = true)
                .isClose(base - 30),
        )
    }

    // Letting go

    /**
     * The paging rule, row for row from the reference scroll view (offset and
     * finger speed at lift-off, and where its page went): thrown, the page goes
     * the way it was thrown however little it had moved; put down, it goes to
     * the nearer side.
     */
    @Test
    fun `a released page goes where a paging scroll view's goes`() {
        val rows = listOf(
            Triple(-9.7, -320.0, Direction.FORWARD),
            Triple(10.0, 320.0, Direction.BACKWARD),
            Triple(-50.3, 0.0, null),
            Triple(-110.7, 0.0, null),
            Triple(-171.0, 0.0, null),
            Triple(-211.0, 0.0, Direction.FORWARD),
            Triple(211.0, 0.0, Direction.BACKWARD),
            Triple(-50.3, -1404.0, Direction.FORWARD),
            Triple(-171.0, -1000.0, Direction.FORWARD),
            Triple(-271.3, -2576.0, Direction.FORWARD),
            // Either side of the throw: the finger's speed at lift-off.
            Triple(-22.0, -292.0, null),
            Triple(-90.3, -284.3, null),
            Triple(-50.3, -260.0, null),
            Triple(-22.0, -337.6, Direction.FORWARD),
            Triple(-22.0, -376.8, Direction.FORWARD),
            Triple(-90.3, -416.0, Direction.FORWARD),
        )
        for ((offset, velocity, expected) in rows) {
            assertEquals(
                "$offset at $velocity", expected,
                PageTurn.settle(offset = offset, velocity = velocity, width = width, canGoBack = true, canGoForward = true),
            )
        }
    }

    @Test
    fun `a throw back against the drag puts the page back, and never turns it the other way`() {
        assertNull(PageTurn.settle(offset = -300.0, velocity = 800.0, width = width, canGoBack = true, canGoForward = true))
        assertNull(PageTurn.settle(offset = -100.0, velocity = 5000.0, width = width, canGoBack = true, canGoForward = true))
    }

    @Test
    fun `however hard it is thrown, a page turns one page`() {
        assertEquals(Direction.FORWARD, PageTurn.settle(offset = -10.0, velocity = -20000.0, width = width, canGoBack = true, canGoForward = true))
        assertNull(
            "a page that never moved has nowhere to be thrown from",
            PageTurn.settle(offset = 0.0, velocity = -20000.0, width = width, canGoBack = true, canGoForward = true),
        )
        assertNull(
            "and there is no page after the last",
            PageTurn.settle(offset = -300.0, velocity = -2000.0, width = width, canGoBack = true, canGoForward = false),
        )
    }

    // Where the pages are

    private val progressSteps = (0..20).map { it * 0.05 }

    @Test
    fun `Slide keeps the two pages edge to edge, and ends where it should`() {
        for (p in progressSteps) {
            val forward = PageTurn.placement(PageTurnStyle.SLIDE, Direction.FORWARD, p, width)
            assertTrue((forward.arrivingX - forward.leavingX).isClose(width))
            assertEquals(0.0, forward.shadowOpacity, 0.0)
            val back = PageTurn.placement(PageTurnStyle.SLIDE, Direction.BACKWARD, p, width)
            assertTrue((back.leavingX - back.arrivingX).isClose(width))
        }
        val start = PageTurn.placement(PageTurnStyle.SLIDE, Direction.FORWARD, 0.0, width)
        val end = PageTurn.placement(PageTurnStyle.SLIDE, Direction.FORWARD, 1.0, width)
        assertTrue(start.leavingX == 0.0 && start.arrivingX == width)
        assertTrue(end.leavingX == -width && end.arrivingX == 0.0)
    }

    @Test
    fun `Cover moves only the top page, the page beneath stays put`() {
        for (p in progressSteps) {
            val forward = PageTurn.placement(PageTurnStyle.COVER, Direction.FORWARD, p, width)
            assertEquals("the next page waits beneath", 0.0, forward.arrivingX, 0.0)
            assertFalse(forward.arrivingOnTop)
            assertTrue(forward.leavingX.isClose(-p * width))
            val back = PageTurn.placement(PageTurnStyle.COVER, Direction.BACKWARD, p, width)
            assertEquals("the page on screen stays while the previous one covers it", 0.0, back.leavingX, 0.0)
            assertTrue(back.arrivingOnTop)
            assertTrue(back.arrivingX.isClose(-(1 - p) * width))
        }
    }

    /** The property that lets a finger catch a page mid-slide and carry it back without a jump. */
    @Test
    fun `a forward turn at p is drawn as a backward one at 1 − p`() {
        for (style in listOf(PageTurnStyle.SLIDE, PageTurnStyle.COVER)) {
            for (p in progressSteps) {
                val forward = PageTurn.placement(style, Direction.FORWARD, p, width)
                val back = PageTurn.placement(style, Direction.BACKWARD, 1 - p, width)
                assertTrue(forward.leavingX.isClose(back.arrivingX))
                assertTrue(forward.arrivingX.isClose(back.leavingX))
                assertTrue(forward.arrivingOnTop != back.arrivingOnTop || style == PageTurnStyle.SLIDE)
                assertTrue(forward.shadowOpacity.isClose(back.shadowOpacity))
                assertTrue(forward.shadowX.isClose(back.shadowX))
            }
        }
    }

    @Test
    fun `Cover's shadow never appears or vanishes in a single step`() {
        var previous = PageTurn.placement(PageTurnStyle.COVER, Direction.FORWARD, 0.0, width)
        assertEquals(PageTurn.SHADOW_OPACITY, previous.shadowOpacity, 0.0)
        for (step in 1..1000) {
            val now = PageTurn.placement(PageTurnStyle.COVER, Direction.FORWARD, step / 1000.0, width)
            assertTrue(abs(now.shadowOpacity - previous.shadowOpacity) < 0.01)
            previous = now
        }
        assertEquals("gone once the page has left", 0.0, previous.shadowOpacity, 0.0)
        assertTrue("cast from the top page's trailing edge", previous.shadowX.isClose(0.0))
    }

    // Timing

    @Test
    fun `the curves start at rest, end at rest, and never go back`() {
        for (curve in listOf(PageTurn.Curve.SineInOut, PageTurn.Curve.Cubic(0.42, 0.0, 0.58, 1.0))) {
            assertEquals(0.0, curve.value(0.0), 0.0)
            assertTrue(curve.value(1.0).isClose(1.0))
            assertTrue("both are symmetric", curve.value(0.5).isClose(0.5))
            var last = 0.0
            for (step in 1..200) {
                val value = curve.value(step / 200.0)
                assertTrue(value >= last)
                last = value
            }
        }
    }

    /** The numbers measured on a paging scroll view and on WebKit, as the constants the reader actually uses. */
    @Test
    fun `a tap's turn takes UIKit's 0_3 s half-cosine on a touch screen and WebKit's 0_2 s on a desktop`() {
        assertEquals(PageTurn.Timing(0.3, PageTurn.Curve.SineInOut), PageTurn.TOUCH_TIMING)
        assertEquals(PageTurn.Timing(0.2, PageTurn.Curve.Cubic(0.42, 0.0, 0.58, 1.0)), PageTurn.MAC_TIMING)
    }

    /** One of the 80 measured animated scrolls, a one-page turn of 402 points, at its own frames (seconds from the start, points along). */
    @Test
    fun `a tap's turn moves as UIKit's animated scroll does, frame for frame`() {
        for ((time, measured) in listOf(0.0490 to 25.67, 0.0823 to 70.00, 0.1490 to 198.67, 0.2156 to 328.33, 0.2656 to 389.00)) {
            val along = PageTurn.TOUCH_TIMING.curve.value(time / PageTurn.TOUCH_TIMING.duration) * 402
            assertTrue("$time: $along against $measured", abs(along - measured) < 0.5)
        }
    }

    @Test
    fun `a tap's motion runs from where it was to where it is going in its time`() {
        val motion = PageTurn.Motion.Timed(from = 0.0, to = 1.0, start = 100.0, timing = PageTurn.TOUCH_TIMING)
        assertEquals(0.0, motion.value(100.0), 0.0)
        assertTrue(motion.value(100.15).isClose(0.5))
        assertEquals(1.0, motion.value(100.3), 0.0)
        assertFalse(motion.isFinished(100.29))
        assertTrue(motion.isFinished(100.3))
    }

    @Test
    fun `a released page leaves at the finger's speed and comes to rest on the page`() {
        val motion = PageTurn.Motion.Spring(from = 0.4, to = 1.0, velocity = 3.0, start = 0.0)
        assertTrue(motion.value(0.0).isClose(0.4))
        val dt = 0.0001
        assertTrue("it keeps the finger's speed at the moment of release", abs((motion.value(dt) - motion.value(0.0)) / dt - 3) < 0.05)
        assertEquals(1.0, motion.value(motion.duration), 0.0)
        assertTrue(abs(motion.value(motion.duration - 0.001) - 1) < 0.001)
        assertTrue(motion.duration < 0.6)
    }

    /**
     * The release spring against a paging scroll view's own frames (seconds
     * from release, points along): a page 171 points across let go at rest,
     * snapping back; one 211 across thrown at 1453 points a second, turning;
     * and one 271 across thrown at 3071, which overshoots its page by nine
     * points and comes back — as the scroll view's did.
     */
    @Test
    fun `a released page moves as a paging scroll view's does, frame for frame`() {
        fun along(motion: PageTurn.Motion, t: Double) = motion.value(t) * 402
        val back = PageTurn.Motion.Spring(from = 171 / 402.0, to = 0.0, velocity = 0.0, start = 0.0)
        for ((t, measured) in listOf(0.0332 to 152.33, 0.0666 to 117.67, 0.0999 to 82.67, 0.1499 to 42.67, 0.2332 to 10.33)) {
            assertTrue(abs(along(back, t) - measured) < 1.5)
        }
        val on = PageTurn.Motion.Spring(from = 211 / 402.0, to = 1.0, velocity = 1453 / 402.0, start = 0.0)
        for ((t, measured) in listOf(0.0325 to 260.00, 0.0658 to 304.67, 0.0991 to 339.67, 0.1491 to 373.67, 0.2325 to 397.00)) {
            assertTrue(abs(along(on, t) - measured) < 1.5)
        }
        val thrown = PageTurn.Motion.Spring(from = 271.33 / 402, to = 1.0, velocity = 3071 / 402.0, start = 0.0)
        for ((t, measured) in listOf(0.0490 to 367.67, 0.1157 to 406.67, 0.1657 to 411.00, 0.2490 to 407.00)) {
            assertTrue(abs(along(thrown, t) - measured) < 1.5)
        }
        assertNotEquals(0.0, thrown.duration, 0.0)
    }
}

/**
 * Where the page sits relative to the bars drawn over it. Ported from
 * `ReaderChromeTests.swift`.
 *
 * The bug these exist for was invisible because the arithmetic lived inline in
 * a view, in a target with no tests: the height budget subtracted one 44-point
 * bar, the footer consumed it, and nothing at all was reserved for the top bar
 * — so every page drew its first lines underneath an opaque toolbar.
 */
class ReaderChromeTest {
    /** A phone with a camera cutout and the shipped margin. */
    private val phone = ReaderChrome(safeAreaTop = 59.0, safeAreaBottom = 34.0, margin = 24.0)
    private val windowWidth = 402.0
    private val windowHeight = 874.0

    @Test
    fun `text never begins underneath the top bar`() {
        assertTrue(phone.topReserve >= phone.safeAreaTop + ReaderChrome.BAR_HEIGHT)
    }

    @Test
    fun `text never ends underneath the footer`() {
        assertTrue(phone.bottomReserve >= phone.safeAreaBottom + ReaderChrome.BAR_HEIGHT)
    }

    @Test
    fun `the reserves and the page exactly fill the window`() {
        val size = phone.pageSize(windowWidth, windowHeight)
        // Nothing unaccounted for: an over-count leaves a gap the reader reads
        // as wasted space, an under-count puts text behind a bar.
        assertEquals(windowHeight, phone.topReserve + size.height + phone.bottomReserve, 0.0)
        assertEquals(windowWidth, size.width + phone.margin * 2, 0.0)
    }

    @Test
    fun `the top bar absorbs the page's top margin rather than stacking with it`() {
        assertEquals(phone.safeAreaTop + ReaderChrome.BAR_HEIGHT, phone.topReserve, 0.0)
        assertTrue(phone.topReserve < phone.safeAreaTop + ReaderChrome.BAR_HEIGHT + phone.margin)
    }

    @Test
    fun `a bigger margin takes width from the page, not from the chrome`() {
        val wide = ReaderChrome(safeAreaTop = 59.0, safeAreaBottom = 34.0, margin = 48.0)
        assertEquals(phone.topReserve, wide.topReserve, 0.0)
        assertTrue(wide.pageSize(windowWidth, windowHeight).width < phone.pageSize(windowWidth, windowHeight).width)
    }

    @Test
    fun `a device with no unsafe edges still reserves both bars`() {
        // The zero-inset first layout pass before the window has been
        // measured must not lay text out into the bars either.
        val flat = ReaderChrome(safeAreaTop = 0.0, safeAreaBottom = 0.0, margin = 24.0)
        assertEquals(ReaderChrome.BAR_HEIGHT, flat.topReserve, 0.0)
        assertEquals(ReaderChrome.BAR_HEIGHT + 24, flat.bottomReserve, 0.0)
    }

    @Test
    fun `a rounded corner is reserved like any other unsafe edge`() {
        // The page's budget has to shrink by exactly as much as the footer
        // moves up, or the last line is pushed under the bar instead of
        // clearing it.
        val cornered = ReaderChrome(safeAreaTop = 0.0, safeAreaBottom = 14.0, margin = 24.0)
        val flat = ReaderChrome(safeAreaTop = 0.0, safeAreaBottom = 0.0, margin = 24.0)
        assertEquals(flat.bottomReserve + 14, cornered.bottomReserve, 0.0)
        assertEquals(flat.topReserve, cornered.topReserve, 0.0)
        assertEquals(flat.pageSize(windowWidth, windowHeight).height - 14, cornered.pageSize(windowWidth, windowHeight).height, 0.0)
    }

    @Test
    fun `a real toolbar replaces the in-page bar but not the page's top margin`() {
        val desktop = ReaderChrome(safeAreaTop = 52.0, safeAreaBottom = 14.0, margin = 24.0, drawsOwnTopBar = false)
        assertEquals(desktop.safeAreaTop + desktop.margin, desktop.topReserve, 0.0)
        assertEquals("a 52-point toolbar and the shipped 24-point margin", 76.0, desktop.topReserve, 0.0)
        // The page never begins above the toolbar, which is where the whole
        // fault started.
        assertTrue(desktop.topReserve >= desktop.safeAreaTop)
        // And it is cheaper than the in-page bar it replaces.
        val flat = ReaderChrome(safeAreaTop = 52.0, safeAreaBottom = 14.0, margin = 24.0)
        assertTrue(desktop.topReserve < flat.topReserve)
        assertEquals("unchanged with a bar of its own", 59 + ReaderChrome.BAR_HEIGHT, phone.topReserve, 0.0)
    }

    @Test
    fun `the reserves still exactly fill the window when there is no in-page top bar`() {
        val desktop = ReaderChrome(safeAreaTop = 52.0, safeAreaBottom = 14.0, margin = 24.0, drawsOwnTopBar = false)
        val size = desktop.pageSize(windowWidth, windowHeight)
        assertEquals(windowHeight, desktop.topReserve + size.height + desktop.bottomReserve, 0.0)
        assertEquals(windowWidth, size.width + desktop.margin * 2, 0.0)
    }

    @Test
    fun `negative insets cannot shrink the reserve`() {
        val odd = ReaderChrome(safeAreaTop = -20.0, safeAreaBottom = -5.0, margin = -10.0)
        assertEquals(ReaderChrome.BAR_HEIGHT, odd.topReserve, 0.0)
        assertEquals(ReaderChrome.BAR_HEIGHT, odd.bottomReserve, 0.0)
    }

    @Test
    fun `a window too short to hold the chrome still yields a usable size`() {
        val size = phone.pageSize(10.0, 10.0)
        // Handed straight to the layout, which lays out nothing at all given a
        // negative box.
        assertTrue(size.width >= 1)
        assertTrue(size.height >= 1)
        assertFalse(phone.fits(10.0, 10.0))
        assertTrue(phone.fits(windowWidth, windowHeight))
    }

    /**
     * There is deliberately no visibility input. This test is the record of
     * that: the page moved on every tap when the layout was measured against
     * the live safe area, and the fix was to measure the window instead.
     */
    @Test
    fun `the page size depends on nothing that a chrome toggle changes`() {
        val before = phone.pageSize(windowWidth, windowHeight)
        val after = ReaderChrome(safeAreaTop = 59.0, safeAreaBottom = 34.0, margin = 24.0).pageSize(windowWidth, windowHeight)
        assertEquals(before, after)
    }
}
