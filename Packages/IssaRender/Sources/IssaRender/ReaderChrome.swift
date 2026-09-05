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
    /// Where it is false, `safeAreaTop` carries the real toolbar height and is
    /// the whole of the top reserve.
    public let drawsOwnTopBar: Bool

    public init(
        safeAreaTop: CGFloat,
        safeAreaBottom: CGFloat,
        margin: CGFloat,
        drawsOwnTopBar: Bool = true,
    ) {
        self.safeAreaTop = max(0, safeAreaTop)
        self.safeAreaBottom = max(0, safeAreaBottom)
        self.margin = max(0, margin)
        self.drawsOwnTopBar = drawsOwnTopBar
    }

    /// Distance from the top of the window to the first line of text.
    ///
    /// The top bar's height absorbs the page's top margin rather than stacking
    /// with it. Forty-four points of empty bar is already more breathing room
    /// than the margin was providing, and adding both is how a reading screen
    /// ends up spending a fifth of its height before the first word.
    public var topReserve: CGFloat {
        safeAreaTop + (drawsOwnTopBar ? Self.barHeight : 0)
    }

    /// Distance from the bottom of the window to the last line of text: the home
    /// indicator, the footer, and the page's own margin above it.
    public var bottomReserve: CGFloat { safeAreaBottom + Self.barHeight + margin }

    /// The area the paginator lays text into.
    ///
    /// Clamped to at least one point in each direction because it is handed
    /// straight to TextKit, which will happily lay out into a negative box and
    /// produce nothing at all.
    public func pageSize(in window: CGSize) -> CGSize {
        CGSize(
            width: max(window.width - margin * 2, 1),
            height: max(window.height - topReserve - bottomReserve, 1),
        )
    }

    /// Whether the window is tall enough to hold the chrome and any text at all.
    ///
    /// False on a window so short that `pageSize` is only returning its clamp —
    /// worth being able to ask, because that is the state in which the layout's
    /// guarantees stop meaning anything.
    public func fits(_ window: CGSize) -> Bool {
        window.height - topReserve - bottomReserve >= 1 && window.width - margin * 2 >= 1
    }
}
