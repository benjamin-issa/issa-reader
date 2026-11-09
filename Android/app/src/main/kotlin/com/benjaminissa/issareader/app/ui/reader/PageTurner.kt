package com.benjaminissa.issareader.app.ui.reader

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.benjaminissa.issareader.app.reader.NeighbourPreview
import com.benjaminissa.issareader.app.reader.PageSnapshot
import com.benjaminissa.issareader.app.reader.ReaderModel
import com.benjaminissa.issareader.render.PageTurn
import com.benjaminissa.issareader.render.PageTurnStyle
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Turns the page the way the reader chose — Slide, Cover or None — and draws
 * nothing itself: [PageTrackView] asks it where the pages are.
 *
 * The model turns first and the page moves after. A tap commits the turn at
 * once and the page it left slides away as a snapshot; a drag commits when the
 * finger lifts. So the reader's place, the narration and TalkBack are exactly
 * as they were before pages moved at all, and a turn interrupted halfway has
 * already happened.
 *
 * Only turns the reader makes go through here. Narration moving the page, a
 * jump from the contents or a search, a rotation — anything else that changes
 * the page — is seen as a page this turner did not expect, and it lets go at
 * once: those change the page in place, as Storyteller's readers do.
 *
 * Lengths are in dp, which is what [PageTurn]'s numbers were measured in (as
 * points); times are seconds on [now]'s clock. Compose snapshot state, so the
 * page track redraws as it moves. Main-thread only: [scope] must dispatch on
 * the main thread, and *post* rather than run in place — a released drag's
 * commit is meant to follow in the next turn of the main thread.
 */
class PageTurner(
    private val model: ReaderModel,
    private val scope: CoroutineScope,
    /** Seconds, on any monotonic clock. Tests hold their own. */
    val now: () -> Double = { System.nanoTime() / 1e9 },
) {
    /** A turn under way: which way, and the page that is not the model's. */
    data class Scene(
        val direction: PageTurn.Direction,
        /**
         * Whether the model's page is the one arriving — after a commit — or
         * the one leaving, while a finger is still deciding.
         */
        val liveIsArriving: Boolean,
        val other: Other,
    )

    sealed interface Other {
        data class Page(val snapshot: PageSnapshot) : Other

        data object Blank : Other
    }

    var scene: Scene? by mutableStateOf(null)
        private set
    var motion: PageTurn.Motion? by mutableStateOf(null)
        private set

    /** Where a dragged page is, as progress through its turn. */
    private var dragProgress by mutableDoubleStateOf(0.0)

    private var styleState by mutableStateOf(PageTurnStyle.SLIDE)

    var style: PageTurnStyle
        get() = styleState
        set(value) {
            if (value == styleState) return
            styleState = value
            // A finger on the page is let go of with the old style; None has
            // no drag to finish, and would otherwise defer every turn to a
            // lift that never comes.
            drag = null
            dragProgress = 0.0
            finish()
            model.keepsNeighbours = value != PageTurnStyle.INSTANT
            runDeferred()
        }

    /** How long a tap's turn takes: the phone's, as the iPhone's. */
    val timing: PageTurn.Timing = PageTurn.TOUCH_TIMING

    /** How far a page travels: the whole width of the reader, in dp. */
    var width: Double = 0.0

    /**
     * The page this turner's own last commit landed on. Any other page
     * arriving means something else moved it.
     */
    private var expectedKey: ReaderModel.PageKey? = null

    private class Drag {
        var tracking = false

        /** Where the page was when the finger caught it, in dp. */
        var base = 0.0
        var offset = 0.0

        /** Given up on: the page moved under the finger. */
        var abandoned = false
        val previews = mutableMapOf<Boolean, NeighbourPreview>()
    }

    private var drag: Drag? = null

    /**
     * Bumped by each released drag that turns the page, and by anything else
     * moving the page: a commit waiting its turn in [chain] goes ahead only if
     * nothing has moved the page since its finger lifted.
     */
    private var dragCommit = 0

    private data class Deferred(val forward: Boolean, val carriesNarration: Boolean, val onCommitted: (() -> Unit)?)

    /** Turns asked for while a finger is on the page, made once it lifts. */
    private var deferred = mutableListOf<Deferred>()

    /** Turns run one after another, in the order they were asked for. */
    private var chain: Job? = null
    private var finishTask: Job? = null
    private var idleTask: Job? = null
    private var seeking = false

    /** The sentence the next seek goes to; see [carryNarration]. */
    private var seekTarget: String? = null

    /**
     * Takes the reader's chosen style and tells the model whether to keep the
     * neighbouring chapters for it.
     *
     * The one place that tells the model. The constructor must not: a screen
     * can build a turner it then throws away, and a write there would turn
     * neighbours back on under a turner that is on None.
     */
    fun adopt(style: PageTurnStyle) {
        this.style = style
        model.keepsNeighbours = style != PageTurnStyle.INSTANT
    }

    /**
     * How far through its turn the page is.
     *
     * A finger that is down but has not yet moved far enough to be a drag —
     * every tap is one — is not dragging anything, and a slide still running
     * carries on under it.
     */
    fun progress(time: Double): Double {
        if (drag?.tracking == true) return dragProgress
        return motion?.value(time) ?: 0.0
    }

    // Taps, keys, TalkBack

    /**
     * Turns the page one way.
     *
     * Never dropped. A turn asked for while the last one is still sliding
     * finishes that one where it was going and starts its own — so a reader
     * tapping quickly through a chapter moves exactly as many pages as they
     * tapped. Storyteller's newer reader refuses turns until the slide ends;
     * this deliberately does not.
     *
     * @param carriesNarration whether a playing voice moves with the page —
     *   TalkBack's turns, where the page is the scrubber. See
     *   [ReaderModel.narrationTargetOnVisiblePage].
     * @param onCommitted once the model has turned.
     */
    fun requestTurn(forward: Boolean, carriesNarration: Boolean = false, onCommitted: (() -> Unit)? = null) {
        if (drag?.tracking == true) {
            deferred.add(Deferred(forward, carriesNarration, onCommitted))
            return
        }
        val previous = chain
        chain = scope.launch {
            previous?.join()
            turn(forward, carriesNarration)
            onCommitted?.invoke()
        }
    }

    private suspend fun turn(forward: Boolean, carriesNarration: Boolean) {
        finish()
        val wasPlaying = model.isPlaying
        if (style == PageTurnStyle.INSTANT) {
            val before = model.pageKey
            if (forward) model.nextPage() else model.previousPage()
            if (carriesNarration && wasPlaying && model.pageKey != before) carryNarration()
            return
        }
        // At a chapter's edge, the next chapter may be on its way already.
        if (model.neighbourIsPending(forward)) {
            model.neighbourSettled(forward)
            finish()
        }
        val leaving = model.currentSnapshot()
        if (drag?.tracking == true || leaving == null) {
            if (forward) model.nextPage() else model.previousPage()
            return
        }
        val direction = if (forward) PageTurn.Direction.FORWARD else PageTurn.Direction.BACKWARD
        // Set before the commit and drawn identically to the page at rest, so
        // no frame can show the new page anywhere but sliding in.
        scene = Scene(direction, liveIsArriving = false, other = Other.Page(leaving))
        val before = model.pageKey
        if (forward) model.nextPage() else model.previousPage()
        val after = model.pageKey
        if (after == before) {
            // The first or last page of the book.
            scene = null
            return
        }
        expectedKey = after
        scene = Scene(direction, liveIsArriving = true, other = Other.Page(leaving))
        start(PageTurn.Motion.Timed(from = 0.0, to = 1.0, start = now(), timing = timing))
        if (carriesNarration && wasPlaying) carryNarration()
    }

    // A finger on the page

    /**
     * The finger moved.
     *
     * @return true the moment the drag becomes a page turn, so the view can
     *   let go of any selection — a swipe clears one, as it always has.
     */
    fun dragChanged(startX: Double, translation: Double): Boolean {
        if (style == PageTurnStyle.INSTANT || !(width > 0)) return false
        if (drag == null) drag = Drag()
        val current = drag ?: return false
        if (current.abandoned) return false
        var began = false
        if (!current.tracking) {
            if (!PageTurn.beginsTracking(startX, translation)) return false
            current.tracking = true
            current.base = caughtOffset()
            began = true
        }
        val canBack = preview(current, forward = false) != NeighbourPreview.None
        val canForward = preview(current, forward = true) != NeighbourPreview.None
        current.offset = PageTurn.trackedOffset(
            translation = translation, base = current.base, width = width,
            canGoBack = canBack, canGoForward = canForward,
        )
        dragProgress = abs(current.offset) / width
        if (current.offset == 0.0) {
            scene = null
        } else {
            val forward = current.offset < 0
            val other = when (val preview = preview(current, forward)) {
                is NeighbourPreview.Page -> Other.Page(preview.snapshot)
                NeighbourPreview.Pending, NeighbourPreview.None -> Other.Blank
            }
            scene = Scene(
                if (forward) PageTurn.Direction.FORWARD else PageTurn.Direction.BACKWARD,
                liveIsArriving = false, other = other,
            )
        }
        return began
    }

    /**
     * The finger lifted.
     *
     * @param velocity dp per second, negative moving left.
     */
    fun dragEnded(velocity: Double) {
        val ended = drag ?: return
        drag = null
        dragProgress = 0.0
        try {
            if (!ended.tracking || ended.abandoned || !(width > 0)) {
                scheduleIdle()
                return
            }
            val canBack = ended.previews[false] != NeighbourPreview.None
            val canForward = ended.previews[true] != NeighbourPreview.None
            val direction = PageTurn.settle(ended.offset, velocity, width, canBack, canForward)
            if (direction == null) {
                settleBack(ended.offset, velocity)
                return
            }
            val forward = direction == PageTurn.Direction.FORWARD
            // Velocity in progress per second, towards the side it turns to.
            val speed = (if (forward) -velocity else velocity) / width
            // Moving from the moment the finger lifts. The commit follows in
            // the next turn of the main thread and only swaps which page is
            // the model's — drawn the same at any progress — so the page never
            // stops.
            start(PageTurn.Motion.Spring(from = abs(ended.offset) / width, to = 1.0, velocity = speed, start = now()))
            dragCommit += 1
            val commit = dragCommit
            // Not behind whatever `chain` holds: a tap waiting for the next
            // chapter must not keep a page the reader has already let go of
            // from turning. Turns asked for after this one still wait for it.
            chain = scope.launch { commitDrag(forward, commit) }
        } finally {
            runDeferred()
        }
    }

    /**
     * The touch ended without a drag the turner should finish: it became a
     * selection, or the system took it away. A cancelled pointer delivers no
     * lift, and a drag left behind would hold every later turn back until the
     * next touch.
     */
    fun dragCancelled() {
        val cancelled = drag ?: return
        drag = null
        dragProgress = 0.0
        try {
            if (!cancelled.tracking || cancelled.abandoned) return
            settleBack(cancelled.offset, 0.0)
        } finally {
            runDeferred()
            scheduleIdle()
        }
    }

    private suspend fun commitDrag(forward: Boolean, commit: Int) {
        // Something else moved the page while this waited, and the turner has
        // already let go of it.
        if (commit != dragCommit) return
        val leaving = model.currentSnapshot() ?: return
        val before = model.pageKey
        if (forward) model.nextPage() else model.previousPage()
        val after = model.pageKey
        if (after == before) {
            // The neighbour said there was a page and the turn found none — a
            // chapter that failed on the way. Back where it came from.
            if (scene != null) {
                val p = motion?.value(now()) ?: 0.0
                start(PageTurn.Motion.Spring(from = p, to = 0.0, velocity = 0.0, start = now()))
            }
            return
        }
        expectedKey = after
        // Still sliding: the model's page becomes the one arriving. Already
        // at rest — the commit waited behind an earlier turn — and there is
        // nothing left to move.
        val scene = scene
        if (scene != null && !scene.liveIsArriving) {
            this.scene = Scene(scene.direction, liveIsArriving = true, other = Other.Page(leaving))
        }
    }

    /** A released page going back where it was. */
    private fun settleBack(offset: Double, velocity: Double) {
        val scene = scene
        if (offset == 0.0 || scene == null) {
            this.scene = null
            return
        }
        val forward = scene.direction == PageTurn.Direction.FORWARD
        val speed = (if (forward) -velocity else velocity) / width
        start(PageTurn.Motion.Spring(from = abs(offset) / width, to = 0.0, velocity = speed, start = now()))
    }

    /**
     * Where a page a finger has just caught is, in dp: at rest, or wherever a
     * turn still sliding has got to.
     *
     * Caught mid-slide, the page the model has turned to becomes the page
     * under the finger and the one sliding away becomes its neighbour, at the
     * same place on screen — a forward turn at `p` is drawn exactly as a
     * backward one at `1 − p` — so nothing jumps.
     */
    private fun caughtOffset(): Double {
        val scene = scene ?: return 0.0
        val motion = motion ?: return 0.0
        val p = motion.value(now())
        this.motion = null
        finishTask?.cancel()
        if (!scene.liveIsArriving) {
            // A page let go of a moment ago and not yet turned to, or one
            // settling back: the same page, further across, and a turn
            // waiting to be made for it is not wanted now that it has been
            // caught.
            dragCommit += 1
            return (if (scene.direction == PageTurn.Direction.FORWARD) -1 else 1) * p * width
        }
        val remaining = (1 - p) * width
        return if (scene.direction == PageTurn.Direction.FORWARD) remaining else -remaining
    }

    private fun preview(drag: Drag, forward: Boolean): NeighbourPreview {
        val known = drag.previews[forward]
        if (known != null && known != NeighbourPreview.Pending) return known
        val fresh = model.neighbourPreview(forward)
        if (fresh == NeighbourPreview.Pending) model.prefetchNeighbours()
        drag.previews[forward] = fresh
        return fresh
    }

    private fun runDeferred() {
        val waiting = deferred
        deferred = mutableListOf()
        for (turn in waiting) requestTurn(turn.forward, turn.carriesNarration, turn.onCommitted)
    }

    // Moving, and stopping

    private fun start(motion: PageTurn.Motion) {
        this.motion = motion
        schedule(motion.duration)
    }

    private fun schedule(after: Double) {
        finishTask?.cancel()
        finishTask = scope.launch {
            delay((after * 1000).toLong().coerceAtLeast(0))
            tick()
        }
    }

    /**
     * Ends the motion if its time is up. Called when it should be; tests call
     * it with their own clock.
     *
     * The motion is timed on [now] and the wake-up on the dispatcher's clock,
     * so a clock that disagrees wakes this early. It asks again for the time
     * that is left, at most one turn's worth, rather than leaving the page
     * where it is until something else finishes it.
     */
    fun tick() {
        val motion = motion ?: return
        val time = now()
        if (!motion.isFinished(time)) {
            val left = motion.start + motion.duration - time
            schedule(min(max(left, 0.01), motion.duration))
            return
        }
        finish()
    }

    /** Puts every page where its turn was going, now. */
    fun finish() {
        finishTask?.cancel()
        finishTask = null
        motion = null
        if (drag?.tracking != true) scene = null
        scheduleIdle()
    }

    /**
     * The model's page changed.
     *
     * Expected, after this turner's own commit: nothing to do. Anything else —
     * narration, a jump, a reflow — moved it, and the page is shown where it
     * now is, at once: the slide was about a page that is no longer the one
     * arriving.
     */
    fun modelKeyChanged(key: ReaderModel.PageKey) {
        try {
            if (key == expectedKey) {
                expectedKey = null
                return
            }
            expectedKey = null
            dragCommit += 1
            drag?.abandoned = true
            finishTask?.cancel()
            motion = null
            scene = null
        } finally {
            scheduleIdle()
        }
    }

    /**
     * Gets the neighbouring chapters ready once the page has been still for a
     * moment, so the work stays off the frames of a turn — unless a finger
     * reaches a chapter's edge first, when it is started at once.
     */
    private fun scheduleIdle() {
        idleTask?.cancel()
        if (style == PageTurnStyle.INSTANT) return
        idleTask = scope.launch {
            delay(IDLE_MILLIS)
            if (motion != null || drag?.tracking == true) return@launch
            model.prefetchNeighbours()
        }
    }

    /**
     * Takes a playing voice to the page just turned to. One seek at a time,
     * and only the last page asked for: a quick run of turns lands the voice
     * on the page they ended on, not on each in turn.
     *
     * The sentence is chosen now, at the commit, rather than when the seek
     * gets to run: narration reaching a sentence boundary in between would
     * move the page back to the voice, and the seek would follow it there.
     */
    private fun carryNarration() {
        val target = model.narrationTargetOnVisiblePage() ?: return
        seekTarget = target
        if (seeking) return
        seeking = true
        scope.launch {
            try {
                while (true) {
                    val next = seekTarget ?: break
                    seekTarget = null
                    model.carryNarration(next)
                }
            } finally {
                seeking = false
            }
        }
    }

    private companion object {
        const val IDLE_MILLIS = 250L
    }
}
