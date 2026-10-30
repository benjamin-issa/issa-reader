package com.benjaminissa.issareader.render

/**
 * Where the reader's page sits inside the window, once its own bars are
 * accounted for.
 *
 * The reader draws its top bar and its footer *over* the page rather than above
 * it, so that showing and hiding them cannot change the page's size — a chrome
 * toggle that re-paginates the chapter is the bug this arrangement exists to
 * prevent. But drawing over the page is only safe if the page never puts text
 * where a bar will be, and that was the part that went wrong: the height budget
 * subtracted one bar, the footer took it, and the top bar was left to paint an
 * opaque band over the first three lines of every page.
 *
 * So the reserve is stated once, here, as a value with no view attached. Every
 * number is a constant of the window and the reader's own margin, never of
 * whether the chrome happens to be visible — which is what keeps the page still.
 *
 * Lengths are in layout units: points on the Swift side, dp here.
 */
class ReaderChrome(
    safeAreaTop: Double,
    safeAreaBottom: Double,
    margin: Double,
    /**
     * Whether the reader draws its own top bar over the page.
     *
     * False where the platform has a real toolbar instead (the Mac, on the
     * Swift side) — and getting this wrong is not cosmetic. The reserve
     * assumed a 44-point in-page bar everywhere, so on the Mac the page began
     * 44 points below the window top while the titlebar and toolbar together
     * occupy about 52. The first line's box sat underneath the toolbar.
     *
     * Where it is false, [safeAreaTop] carries the real toolbar height, and the
     * page's own margin sits below it — the bar that would otherwise have
     * stood in for that margin is not there to do it.
     */
    val drawsOwnTopBar: Boolean = true,
) {
    /**
     * The device's unsafe top edge — a cutout or a status bar — as it is with
     * the status bar showing. Held rather than observed.
     */
    val safeAreaTop: Double = maxOf(0.0, safeAreaTop)
    val safeAreaBottom: Double = maxOf(0.0, safeAreaBottom)

    /** The page's own margin, from [ReaderStyle.pageMargin]. */
    val margin: Double = maxOf(0.0, margin)

    /** A width and a height. */
    data class Size(val width: Double, val height: Double)

    /**
     * Distance from the top of the window to the first line of text.
     *
     * The top bar's height absorbs the page's top margin rather than stacking
     * with it. Forty-four points of empty bar is already more breathing room
     * than the margin was providing, and adding both is how a reading screen
     * ends up spending a fifth of its height before the first word.
     *
     * Where there is no such bar, the margin has to be spent after all: a
     * margin the other three edges get is not one the top can go without; it
     * is only ever waived because something taller is already standing there.
     */
    val topReserve: Double get() = safeAreaTop + (if (drawsOwnTopBar) BAR_HEIGHT else margin)

    /**
     * Distance from the bottom of the window to the last line of text: the
     * gesture bar, the footer, and the page's own margin above it.
     */
    val bottomReserve: Double get() = safeAreaBottom + BAR_HEIGHT + margin

    /**
     * The area the paginator lays text into.
     *
     * Clamped to at least one unit in each direction because it is handed
     * straight to the layout, which will happily lay out into a negative box
     * and produce nothing at all.
     */
    fun pageSize(windowWidth: Double, windowHeight: Double): Size = Size(
        width = maxOf(windowWidth - margin * 2, 1.0),
        height = maxOf(windowHeight - topReserve - bottomReserve, 1.0),
    )

    /**
     * Whether the window is tall enough to hold the chrome and any text at all.
     *
     * False on a window so short that [pageSize] is only returning its clamp —
     * worth being able to ask, because that is the state in which the layout's
     * guarantees stop meaning anything.
     */
    fun fits(windowWidth: Double, windowHeight: Double): Boolean =
        windowHeight - topReserve - bottomReserve >= 1 && windowWidth - margin * 2 >= 1

    override fun equals(other: Any?): Boolean = other is ReaderChrome && safeAreaTop == other.safeAreaTop &&
        safeAreaBottom == other.safeAreaBottom && margin == other.margin && drawsOwnTopBar == other.drawsOwnTopBar

    override fun hashCode(): Int = listOf(safeAreaTop, safeAreaBottom, margin, drawsOwnTopBar).hashCode()

    companion object {
        /**
         * Both of the reader's bars are this tall. It is also the smallest
         * square a finger can reliably hit, which is why the bars are not made
         * shorter to win the space back.
         */
        const val BAR_HEIGHT = 44.0

        /**
         * The least a navigation band must be, in dp, to hold the book's title
         * under the footer. Android draws its gesture handle across the middle
         * of the band, not at its foot as the iPhone does, so the title set at
         * the band's top has only the upper half: a line of caption type (13
         * dp) and a little air above the handle's 4 dp need 34. The usual 24
         * dp gesture bar has no room, and a title there was drawn through the
         * handle.
         */
        const val BOOK_TITLE_BAND_MINIMUM = 34.0

        /**
         * Whether the book's title is drawn in the band under the footer.
         *
         * The setting, the chrome showing, gestural navigation, and a band tall
         * enough to hold a line of caption type above the gesture handle. Gestural navigation is read off
         * the insets: the bar is there (navigation bars' bottom is more than
         * zero) but nothing in it is tappable (tappable element's bottom is
         * zero). Three-button navigation has buttons in the band, which a title
         * would sit among, so it never gets one.
         *
         * A pure function of its inputs, so the rule is tested without a window.
         *
         * @param navBarBottomDp the navigation bar's bottom inset, ignoring visibility.
         * @param tappableBottomDp the tappable-element bottom inset, ignoring visibility.
         */
        fun showsBookTitle(setting: Boolean, chromeVisible: Boolean, navBarBottomDp: Double, tappableBottomDp: Double): Boolean =
            setting && chromeVisible && tappableBottomDp <= 0.0 && navBarBottomDp >= BOOK_TITLE_BAND_MINIMUM
    }
}
