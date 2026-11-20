import CoreGraphics
import Foundation

/// Where the reader's page sits inside the window, once its own bars are
/// accounted for.
///
/// The reader draws its top bar and its footer *over* the page rather than above
/// it, so that showing and hiding them cannot change the page's size — a chrome
/// toggle that re-paginates the chapter is the bug this arrangement exists to
/// prevent. But drawing over the page is only safe if the page never puts text
/// where a bar will be, and that was the part that went wrong: the height budget
/// subtracted one bar, the footer took it, and the top bar was left to paint an
/// opaque band over the first three lines of every page.
///
/// So the reserve is stated once, here, as a value with no view attached. Every
/// number is a constant of the window and the reader's own margin, never of
/// whether the chrome happens to be visible — which is what keeps the page still.
public struct ReaderChrome: Sendable, Equatable {
    /// Both of the reader's bars are this tall. It is also the smallest square a
    /// finger can reliably hit, which is why the bars are not made shorter to
    /// win the space back.
    public static let barHeight: CGFloat = 44

    /// The device's unsafe top edge — the notch or the Dynamic Island — as it is
    /// with the status bar showing. Held rather than observed; see `ReaderInsets`.
    public let safeAreaTop: CGFloat
    public let safeAreaBottom: CGFloat
    /// The page's own margin, from `ReaderStyle.pageMargin`.
    public let margin: CGFloat
    /// Whether the reader draws its own top bar over the page.
    ///
    /// False on the Mac, which has a real window toolbar instead — and getting
    /// this wrong is not cosmetic. The reserve assumed a 44-point in-page bar
    /// on every platform, so on macOS the page began 44 points below the window
    /// top while the titlebar and toolbar together occupy about 52. The first
    /// line's box sat underneath the toolbar, and only stayed legible because
    /// the leading above the glyphs happened to cover the difference: tighten
    /// the line spacing or shrink the face and the first line goes under the
    /// chrome.
    ///
    /// Where it is false, `safeAreaTop` carries the real toolbar height, and
    /// the page's own margin sits below it — the bar that would otherwise have
    /// stood in for that margin is not there to do it.
    public let drawsOwnTopBar: Bool
    /// The band down one side that the reader's tools stand in where the
    /// system runs its bars down a side (iPhone Duo): the window's unsafe edge
    /// there, held like the top and bottom ones. Zero everywhere else.
    ///
    /// With a rail there is no top bar, so `drawsOwnTopBar` is false and the
    /// page's own margin is spent at the top, as on the Mac.
    public let railWidth: CGFloat
    /// Whether the reader has given its bars' bands to the page
    /// (`ReaderStyle.fillsScreen`).
    ///
    /// The controls are then drawn over the text when summoned, so the page
    /// reserves nothing for them: not the footer's band, and not the top bar's
    /// either. What the hardware takes stays taken — the Dynamic Island, the
    /// home indicator, the Duo's rail — because text under those is simply
    /// lost, not covered for a moment.
    public let fillsScreen: Bool
    /// The margin above the first line and below the last when the page fills
    /// the screen; the sides keep `margin`. Equal to `margin` unless given.
    public let verticalMargin: CGFloat
    /// How far into the safe areas the full-screen page may reach, where that
    /// is known. Nil keeps the safe areas whole.
    public let fillEdges: FillEdges?
    /// How far in from each side the page starts, where the device's own side
    /// edges are in the way: an iPhone on its side, with the sensor housing
    /// down one of them. Zero everywhere else, and upright.
    public let sideLeading: CGFloat
    public let sideTrailing: CGFloat

    public init(
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat,
        margin: CGFloat,
        drawsOwnTopBar: Bool = true,
        railWidth: CGFloat = 0,
        fillsScreen: Bool = false,
        verticalMargin: CGFloat? = nil,
        fillEdges: FillEdges? = nil,
        sideLeading: CGFloat = 0,
        sideTrailing: CGFloat = 0,
    ) {
        self.safeAreaTop = max(0, safeAreaTop)
        self.safeAreaBottom = max(0, safeAreaBottom)
        self.margin = max(0, margin)
        self.railWidth = max(0, railWidth)
        self.fillsScreen = fillsScreen
        self.verticalMargin = max(0, verticalMargin ?? margin)
        self.fillEdges = fillEdges
        self.sideLeading = max(0, sideLeading)
        self.sideTrailing = max(0, sideTrailing)
        self.drawsOwnTopBar = drawsOwnTopBar && self.railWidth == 0
    }

    /// Distance from the top of the window to the first line of text.
    ///
    /// The top bar's height absorbs the page's top margin rather than stacking
    /// with it. Forty-four points of empty bar is already more breathing room
    /// than the margin was providing, and adding both is how a reading screen
    /// ends up spending a fifth of its height before the first word.
    ///
    /// Where there is no such bar, the margin has to be spent after all. The
    /// Mac reserved the toolbar's height and nothing more, so the first line
    /// began flush against the toolbar with no air at all above it and its
    /// ascenders shaved by the canvas's clip. A margin the other three edges
    /// get is not one the top can go without; it is only ever waived because
    /// something taller is already standing there.
    ///
    /// With the page filling the screen the bar is not there to stand in for
    /// the margin either, so the margin is spent, as it is where there is no
    /// bar at all.
    ///
    /// Filling the screen, the top margin is the vertical one, and the
    /// hardware's share may be less than the whole safe area (`hardwareTop`).
    public var topReserve: CGFloat {
        fillsScreen ? hardwareTop + verticalMargin : safeAreaTop + (drawsOwnTopBar ? Self.barHeight : margin)
    }

    /// How much of the top safe area the page keeps clear. The whole of it,
    /// unless the page fills the screen and the device's edges are known: then
    /// the sensor housing, or the corner at the side margin's depth, whichever
    /// reaches further. Never more than the safe area.
    public var hardwareTop: CGFloat {
        guard fillsScreen, let edges = fillEdges else { return safeAreaTop }
        return min(safeAreaTop, max(edges.sensorClearance, edges.corner.depth(forInset: margin)))
    }

    /// The bottom safe area's counterpart: the home indicator, or the corner.
    public var hardwareBottom: CGFloat {
        guard fillsScreen, let edges = fillEdges else { return safeAreaBottom }
        return min(safeAreaBottom, max(edges.indicatorClearance, edges.corner.depth(forInset: margin)))
    }

    /// Distance from the bottom of the window to the last line of text: the home
    /// indicator, the footer, and the page's own margin above it. The footer's
    /// band is left out when the page fills the screen, since the footer is
    /// then drawn over the text.
    public var bottomReserve: CGFloat {
        fillsScreen ? hardwareBottom + verticalMargin : safeAreaBottom + Self.barHeight + margin
    }

    /// The area the paginator lays text into.
    ///
    /// Clamped to at least one point in each direction because it is handed
    /// straight to TextKit, which will happily lay out into a negative box and
    /// produce nothing at all.
    public func pageSize(in window: CGSize) -> CGSize {
        CGSize(
            width: max(window.width - railWidth - sideLeading - sideTrailing - margin * 2, 1),
            height: max(window.height - topReserve - bottomReserve, 1),
        )
    }

    /// Whether the window is tall enough to hold the chrome and any text at all.
    ///
    /// False on a window so short that `pageSize` is only returning its clamp —
    /// worth being able to ask, because that is the state in which the layout's
    /// guarantees stop meaning anything.
    public func fits(_ window: CGSize) -> Bool {
        window.height - topReserve - bottomReserve >= 1 && window.width - railWidth - sideLeading - sideTrailing - margin * 2 >= 1
    }
}
