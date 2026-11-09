package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.input.pointer.AwaitPointerEventScope
import androidx.compose.ui.input.pointer.PointerId
import androidx.compose.ui.input.pointer.PointerInputChange
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.input.pointer.util.addPointerInputChange

/**
 * What a finger on the page can mean, in the page track's own coordinates,
 * in dp: the padded frame, whose left edge is the reader's.
 */
interface PageGestures {
    /** Whether a second tap is waited for. Only where it could play something. */
    val doubleTapEnabled: Boolean

    /** A finger went down: a new touch, which has not selected anything yet. */
    fun touchBegan()

    /**
     * The finger is at [x], having started at [startX]: the page follows it
     * once it is a drag. True when this is the moment it became one.
     */
    fun moved(startX: Float, translationX: Float): Boolean

    /** Held for the long-press time without moving: select there. True when something was selected. */
    fun longPressed(at: Offset): Boolean

    /** A held finger moving, extending its selection. */
    fun selectionMoved(to: Offset)

    /** The finger lifted, having started at [startX] and travelled [translationX] at [velocityX] dp a second. */
    fun lifted(startX: Float, translationX: Float, velocityX: Float, selecting: Boolean)

    /** The system took the touch away. */
    fun cancelled()

    fun tapped(at: Offset)

    fun doubleTapped(at: Offset)
}

/**
 * One recogniser for the whole page, which is what the iPhone's simultaneous
 * drag, long press, tap and double tap amount to, in the order they resolve:
 *
 * - every touch is a drag from its first moment — the page follows it once it
 *   has moved [PageTurn.TRACKING_SLOP], and lift-off decides the turn;
 * - held [LONG_PRESS_MILLIS] without moving that far, it selects the sentence
 *   under the finger, and from then on moving extends the selection;
 * - lifted without moving or being held, it is a tap — after waiting out the
 *   double-tap window, but only where a double tap could do something, so a
 *   plain book's taps are not all charged for a gesture with nothing to play.
 *
 * A pointer the system takes away (a back gesture from the edge) arrives as a
 * lift already consumed, and is a cancellation, not a tap.
 */
@Composable
fun Modifier.pageGestures(handler: PageGestures): Modifier {
    val current by rememberUpdatedState(handler)
    return pointerInput(Unit) {
        val slop = SLOP_DP * density
        fun dp(value: Float) = value / density
        fun dp(offset: Offset) = Offset(offset.x / density, offset.y / density)

        /**
         * One finger from down to up. Returns where it was tapped, or null
         * when it was anything but a tap.
         */
        suspend fun AwaitPointerEventScope.track(down: PointerInputChange): Offset? {
            current.touchBegan()
            val id: PointerId = down.id
            val start = down.position
            var position = start
            val tracker = VelocityTracker()
            tracker.addPointerInputChange(down)
            var moved = false
            var selecting = false
            var lifted: PointerInputChange? = null
            // With minimum distance zero, a drag begins with the touch.
            current.moved(dp(start.x), 0f)

            fun follow(change: PointerInputChange) {
                position = change.position
                tracker.addPointerInputChange(change)
                if (selecting) {
                    current.selectionMoved(dp(position))
                    change.consume()
                } else if (current.moved(dp(start.x), dp(position.x - start.x))) {
                    change.consume()
                }
            }

            // Until the long press is due: a lift, or a finger that has moved
            // too far to be holding still.
            var gone = false
            val ended = withTimeoutOrNull(LONG_PRESS_MILLIS) {
                while (true) {
                    val change = awaitPointerEvent().changes.firstOrNull { it.id == id }
                    if (change == null) {
                        gone = true
                        break
                    }
                    if (!change.pressed) {
                        lifted = change
                        break
                    }
                    follow(change)
                    if ((change.position - start).getDistance() > slop) {
                        moved = true
                        break
                    }
                }
                true
            }
            if (gone) {
                current.cancelled()
                return null
            }
            val heldStill = ended == null
            var longPressed = false
            if (heldStill && lifted == null) {
                longPressed = true
                selecting = current.longPressed(dp(position))
            }
            while (lifted == null) {
                val change = awaitPointerEvent().changes.firstOrNull { it.id == id }
                if (change == null) {
                    current.cancelled()
                    return null
                }
                if (!change.pressed) {
                    lifted = change
                    break
                }
                follow(change)
                if ((change.position - start).getDistance() > slop) moved = true
            }
            val up = lifted ?: return null
            if (up.isConsumed) {
                // Taken away, not lifted.
                current.cancelled()
                return null
            }
            tracker.addPointerInputChange(up)
            val velocity = tracker.calculateVelocity()
            current.lifted(dp(start.x), dp(up.position.x - start.x), dp(velocity.x), selecting)
            if (selecting) up.consume()
            return if (!moved && !longPressed) dp(up.position) else null
        }

        awaitEachGesture {
            val first = awaitFirstDown(requireUnconsumed = false)
            val tap = track(first) ?: return@awaitEachGesture
            if (!current.doubleTapEnabled) {
                current.tapped(tap)
                return@awaitEachGesture
            }
            val second = withTimeoutOrNull(viewConfiguration.doubleTapTimeoutMillis) {
                awaitFirstDown(requireUnconsumed = false)
            }
            if (second == null) {
                current.tapped(tap)
                return@awaitEachGesture
            }
            val again = track(second) ?: return@awaitEachGesture
            current.doubleTapped(again)
        }
    }
}

/** How long a press must be held to select: the iPhone's 0.35 s. */
const val LONG_PRESS_MILLIS = 350L

/** How far a held finger may wander and still be holding still, in dp. */
private const val SLOP_DP = 10f
