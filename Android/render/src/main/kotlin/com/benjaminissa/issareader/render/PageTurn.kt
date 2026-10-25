package com.benjaminissa.issareader.render

import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * How a page moves when the reader turns it. A choice in Settings, on every
 * platform that turns pages.
 *
 * Slide is the default because it is what the Storyteller readers do: the
 * App Store app turns a page with Readium's animated `UIScrollView` offset,
 * and its newer Swift reader with WebKit's smooth scroll over CSS scroll
 * snapping — both a push, the old page and the new travelling together.
 * Cover is Apple Books' "Slide": the page lifts away over the next one, which
 * waits underneath. None is how every page turned before 1.5.0.
 */
enum class PageTurnStyle(val rawValue: String, val title: String) {
    SLIDE("slide", "Slide"),
    COVER("cover", "Cover"),

    /** Stored as "none", the Swift client's spelling. */
    INSTANT("none", "None"),
    ;

    val id: String get() = rawValue

    companion object {
        fun fromRawValue(raw: String): PageTurnStyle? = entries.firstOrNull { it.rawValue == raw }
    }
}

/**
 * The rules a page turn follows: when a drag becomes a turn, where each page
 * is at every point of one, and how long it takes to get there.
 *
 * Pure, and in one place, so that every number is measured once and tested
 * once. The view only asks. Lengths are in layout units (points on the Swift
 * side, where they were measured; dp here), times in seconds.
 */
object PageTurn {
    enum class Direction { FORWARD, BACKWARD }

    /**
     * The style a turn actually gets. Reduce Motion (on Android, removed
     * animations) is a promise the system makes on the reader's behalf, and
     * Storyteller's newer reader keeps it the same way: the animation goes,
     * and the setting says why.
     */
    fun effectiveStyle(chosen: PageTurnStyle, reduceMotion: Boolean): PageTurnStyle =
        if (reduceMotion) PageTurnStyle.INSTANT else chosen

    // The swipe that turns on lift-off

    /**
     * The leading strip that belongs to the system. A back gesture from the
     * very edge shuts the book; a page that also turned on the way out was a
     * bug.
     */
    const val DISMISS_EDGE = 20.0

    /**
     * How far a finger must travel, with nothing following it, for lift-off to
     * count as a swipe rather than an untidy tap.
     */
    const val LIFT_OFF_DISTANCE = 24.0

    /**
     * The 1.4.1 swipe, kept verbatim for None and for Reduce Motion: decided
     * only when the finger lifts, with nothing on screen following it.
     */
    fun liftOffSwipe(startX: Double, translation: Double): Direction? {
        if (!(startX > DISMISS_EDGE) || !(abs(translation) >= LIFT_OFF_DISTANCE)) return null
        return if (translation < 0) Direction.FORWARD else Direction.BACKWARD
    }

    // A page that follows the finger

    /**
     * How far a finger travels before the page starts to follow it.
     *
     * `UIScrollView`'s pan recogniser waits for this much movement too, and
     * then — measured on a paging scroll view — moves the page by the finger's
     * travel *past* that point, never jumping to catch up the distance it
     * waited for.
     */
    const val TRACKING_SLOP = 10.0

    /** Whether a touch has become a drag that moves the page. */
    fun beginsTracking(startX: Double, translation: Double): Boolean =
        startX > DISMISS_EDGE && abs(translation) >= TRACKING_SLOP

    /**
     * Where the page sits under a finger: one for one, from the point the drag
     * began tracking, and held at rest towards a side with no page to show —
     * Readium and the Storyteller readers do not rubber-band past the first or
     * last page of a book, and neither does this.
     *
     * Negative is the page moving left, which is turning forward.
     *
     * @param translation the finger's travel since it went down.
     * @param base where the page already was when the finger caught it — a
     *   page caught mid-slide carries on from there, not from rest.
     */
    fun trackedOffset(
        translation: Double,
        base: Double = 0.0,
        width: Double,
        canGoBack: Boolean,
        canGoForward: Boolean,
    ): Double {
        val past = translation - TRACKING_SLOP * (if (translation < 0) -1 else 1)
        val raw = base + (if (abs(translation) < TRACKING_SLOP) 0.0 else past)
        val lower = if (canGoForward) -width else 0.0
        val upper = if (canGoBack) width else 0.0
        return min(max(raw, lower), upper)
    }

    // Letting go

    /**
     * The slowest a finger can be moving as it lifts and still count as
     * throwing the page rather than putting it down, in units a second.
     *
     * Below it the page goes to whichever side holds more of it. At or above
     * it the page goes the way it was thrown, however little of it had moved
     * — a ten-point flick turns the page, as it does in any paging scroll
     * view. Measured on one: across 96 drags, every lift at 292 points a
     * second or slower settled to the nearer page, and every lift at 320 or
     * faster went the way it was thrown.
     */
    const val FLICK_VELOCITY = 300.0

    /**
     * Which way a released page goes, by `UIScrollView`'s paging rule.
     *
     * Measured on a paging scroll view driven by 96 synthesised drags, and it
     * is not the projected-distance rule Apple recommends for free-standing
     * gestures: thrown, the page goes to the next page in the direction it is
     * moving — a ceiling or a floor of how far it has travelled — and put
     * down, to the nearer page. Never more than one page from where it
     * started.
     *
     * @param offset where the page is, negative towards the next page.
     * @param velocity the finger's speed as it lifted, units per second,
     *   negative moving left.
     * @return `null` when the page settles back where it was.
     */
    fun settle(offset: Double, velocity: Double, width: Double, canGoBack: Boolean, canGoForward: Boolean): Direction? {
        if (!(width > 0)) return null
        // In the scroll view's own terms: pages travelled towards the next
        // page, and the speed it is travelling that way.
        val travelled = -offset / width
        val moving = -velocity
        val pages = when {
            moving >= FLICK_VELOCITY -> ceil(travelled)
            moving <= -FLICK_VELOCITY -> floor(travelled)
            // Swift's `rounded()`: to nearest, halves away from zero.
            else -> if (travelled >= 0) floor(travelled + 0.5) else -floor(-travelled + 0.5)
        }
        if (pages >= 1 && canGoForward) return Direction.FORWARD
        if (pages <= -1 && canGoBack) return Direction.BACKWARD
        return null
    }

    /**
     * The spring a released page settles along, as `UIScrollView` paging lets
     * go: a natural frequency of 16.5 radians a second (a response of
     * 0.381 s) at 0.9 of critical damping, starting at the finger's speed.
     *
     * Fitted to every frame of 66 releases of a paging scroll view on the
     * iPhone 17 Pro simulator — snapping back and turning, from rest and from
     * flicks up to 3200 points a second — to 0.47 pt RMS and 3.4 pt at worst.
     * Not critically damped: thrown hard, a paging scroll view overshoots the
     * page by a few points and comes back, and so does this.
     */
    const val RELEASE_FREQUENCY = 16.5
    const val RELEASE_DAMPING = 0.9

    // Where the pages are

    /** Both pages of a turn, at one moment of it. */
    data class Placement(
        /** The page being turned away from. */
        val leavingX: Double,
        /** The page being turned to. */
        val arrivingX: Double,
        /** Which of the two is drawn above the other. Only Cover cares. */
        val arrivingOnTop: Boolean,
        /** The shadow a covering page casts along its trailing edge, 0 when there is none. */
        val shadowOpacity: Double,
        /** Where that shadow begins: the top page's trailing edge. */
        val shadowX: Double,
    )

    /**
     * The darkest a covering page's shadow gets, and how far it reaches.
     * Readest's cover turn, the closest open implementation of Apple Books',
     * draws 28 points at 35% black.
     */
    const val SHADOW_OPACITY = 0.35
    const val SHADOW_WIDTH = 28.0

    /**
     * Where both pages are, [progress] of the way through a turn.
     *
     * One parameter for every style, so that a forward turn at `p` is drawn
     * exactly as a backward one at `1 − p` with the pages swapped — which is
     * what lets a finger catch a page mid-slide and carry it back without a
     * jump.
     */
    fun placement(style: PageTurnStyle, direction: Direction, progress: Double, width: Double): Placement {
        // Held near the ends rather than at them: the release spring
        // overshoots by a few points, as a paging scroll view's does.
        val p = min(max(progress, -0.1), 1.1)
        val forward = direction == Direction.FORWARD
        return when (style) {
            PageTurnStyle.SLIDE, PageTurnStyle.INSTANT -> if (forward) {
                Placement(-p * width, (1 - p) * width, arrivingOnTop = false, shadowOpacity = 0.0, shadowX = 0.0)
            } else {
                Placement(p * width, -(1 - p) * width, arrivingOnTop = false, shadowOpacity = 0.0, shadowX = 0.0)
            }
            PageTurnStyle.COVER -> {
                // Forward, the page on screen lifts away to the left and the
                // next one waits beneath it. Back, the previous page comes in
                // from the left over the one on screen. Either way the top page
                // is the one that moves, and its trailing edge casts the shadow.
                val topX = if (forward) -p * width else -(1 - p) * width
                // Faded over the last tenth of the top page's travel, so the
                // shadow never appears or vanishes in a single frame.
                val showing = min(max(if (forward) 1 - p else p, 0.0), 1.0)
                val opacity = SHADOW_OPACITY * min(1.0, showing / 0.1)
                if (forward) {
                    Placement(topX, 0.0, arrivingOnTop = false, shadowOpacity = opacity, shadowX = topX + width)
                } else {
                    Placement(0.0, topX, arrivingOnTop = true, shadowOpacity = opacity, shadowX = topX + width)
                }
            }
        }
    }

    // Timing

    /** How progress runs against time. */
    sealed interface Curve {
        /**
         * Half a cosine: `(1 − cos πu) / 2`. What `UIScrollView` uses for an
         * animated `setContentOffset`, to 0.27 pt RMS; see [TOUCH_TIMING].
         */
        data object SineInOut : Curve

        /** A CSS-style cubic Bézier through (0,0) and (1,1). */
        data class Cubic(val x1: Double, val y1: Double, val x2: Double, val y2: Double) : Curve

        fun value(u: Double): Double {
            // Exactly at rest at both ends, whatever the arithmetic in between.
            if (u <= 0) return 0.0
            if (u >= 1) return 1.0
            return when (this) {
                SineInOut -> (1 - cos(Math.PI * u)) / 2
                is Cubic -> bezier(u, x1, y1, x2, y2)
            }
        }

        private companion object {
            /**
             * y for x on a cubic Bézier, by bisection on its parameter. Sixty
             * halvings is far below a pixel, and the curve is monotonic in x
             * for every control point a timing function may have.
             */
            fun bezier(x: Double, x1: Double, y1: Double, x2: Double, y2: Double): Double {
                var lo = 0.0
                var hi = 1.0
                repeat(60) {
                    val t = (lo + hi) / 2
                    val bx = 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t
                    if (bx < x) lo = t else hi = t
                }
                val t = (lo + hi) / 2
                return 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t
            }
        }
    }

    /** How long a tap's turn takes, and along what curve. */
    data class Timing(val duration: Double, val curve: Curve)

    /**
     * A tap, a key or the remote, on a touch screen or a television: exactly
     * what Readium's turn does, since that is
     * `UIScrollView.setContentOffset(_:animated: true)`.
     *
     * Measured, not looked up — Apple publishes neither number. On the iPhone
     * 17 Pro simulator, 80 animated scrolls of 100 pt, half a page, a page and
     * two pages, sampled every frame: the duration is 0.300 s whatever the
     * distance, and the curve is a half cosine, which fits every sample to
     * 0.27 pt RMS and 1.3 pt at worst. The usual Bézier eases miss by 2 to
     * 40 pt.
     */
    val TOUCH_TIMING = Timing(duration = 0.3, curve = Curve.SineInOut)

    /**
     * A desktop window: WebKit's smooth scroll, which is what Storyteller's
     * newer reader turns pages with there. `ScrollAnimationSmooth` takes
     * distance over 1000 points a second, capped at 200 ms, along CSS
     * `ease-in-out` — and a page is never narrow enough to come in under the
     * cap.
     */
    val MAC_TIMING = Timing(duration = 0.2, curve = Curve.Cubic(0.42, 0.0, 0.58, 1.0))

    /**
     * Progress over time, from wherever a turn was to wherever it is going.
     *
     * Computed rather than handed to the animation system, so that a turn
     * interrupted by the next tap, or caught by a finger, is exactly where it
     * appears to be — and so that it can be tested against a clock.
     */
    sealed interface Motion {
        val target: Double
        val start: Double

        /** A turn the reader asked for with a tap, a key or the remote. */
        data class Timed(val from: Double, val to: Double, override val start: Double, val timing: Timing) : Motion {
            override val target: Double get() = to
        }

        /** A released drag finishing its turn, or settling back. [velocity] is in progress per second. */
        data class Spring(val from: Double, val to: Double, val velocity: Double, override val start: Double) : Motion {
            override val target: Double get() = to
        }

        /**
         * How long it runs. A spring's is when its envelope falls under
         * [REST], which bounds every overshoot as well.
         */
        val duration: Double
            get() = when (this) {
                is Timed -> timing.duration
                is Spring -> {
                    val w = RELEASE_FREQUENCY
                    val z = RELEASE_DAMPING
                    val wd = w * sqrt(1 - z * z)
                    val d0 = from - to
                    val amplitude = sqrt(d0 * d0 + ((velocity + z * w * d0) / wd).pow(2))
                    if (amplitude > REST) ln(amplitude / REST) / (z * w) else 0.0
                }
            }

        fun isFinished(time: Double): Boolean =
            // A nanosecond's grace: a clock read as start + duration can come
            // back a hair short of it after the subtraction.
            time - start >= duration - 1e-9

        fun value(time: Double): Double {
            val t = max(time - start, 0.0)
            if (isFinished(time)) return target
            return when (this) {
                is Timed -> from + (to - from) * timing.curve.value(t / timing.duration)
                is Spring -> {
                    // x'' = −ω²x − 2ζωx', underdamped, from displacement d0
                    // and velocity v0.
                    val w = RELEASE_FREQUENCY
                    val z = RELEASE_DAMPING
                    val wd = w * sqrt(1 - z * z)
                    val d0 = from - to
                    val displacement = exp(-z * w * t) * (d0 * cos(wd * t) + (velocity + z * w * d0) / wd * sin(wd * t))
                    to + displacement
                }
            }
        }

        companion object {
            /** Close enough to the end, in progress, to stop: a fifth of a point on a 400-point page. */
            const val REST = 0.0005
        }
    }
}
