package com.benjaminissa.issareader.render

/**
 * Which part of the page a tap landed in.
 *
 * The outer strips turn pages and the rest shows or hides the chrome, which is
 * what upstream Storyteller and Kindle both do. Split out of the view so the
 * boundaries can be tested: the original test compared an x in the padded
 * frame's space against the canvas width, so the back zone was a margin
 * narrower than intended and shifted inward.
 *
 * Lengths are in the reader's layout units (points on the Swift side, density
 * independent pixels here), which is what makes [REACH_PAST_MARGIN] a finger.
 */
enum class ReaderTapZone {
    BACK,
    MIDDLE,
    FORWARD,
    ;

    companion object {
        /**
         * How far a page-turn strip reaches past the margin.
         *
         * A turn zone wants to sit over whitespace, so it is sized from the
         * margin rather than the page: one margin, plus a finger. Measured in
         * points because a finger is the same size on every device — a plain
         * quarter of the width put 74pt of live text under "go back" on a phone
         * and 232pt of it on a tablet, which is what makes a reader aiming at a
         * sentence turn the page by accident.
         */
        const val REACH_PAST_MARGIN = 44.0

        /**
         * @param x horizontal position in the PADDED frame, which is what a tap
         *   on the padded canvas reports.
         * @param pageWidth the canvas width, inside the margins.
         * @param margin the page margin applied on each side.
         */
        fun of(x: Double, pageWidth: Double, margin: Double): ReaderTapZone {
            val full = pageWidth + margin * 2
            if (!(full > 0)) return MIDDLE
            // Still capped as a fraction, so the two strips can never crowd
            // out the middle on a narrow page — a split screen, or a pop-up
            // window.
            val strip = minOf(margin + REACH_PAST_MARGIN, full * 0.25)
            if (x < strip) return BACK
            if (x > full - strip) return FORWARD
            return MIDDLE
        }
    }
}
