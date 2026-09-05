import CoreGraphics
import Foundation
import Testing

@testable import IssaRender

/// Where the page sits relative to the bars drawn over it.
///
/// The bug these exist for was invisible because the arithmetic lived inline in
/// a SwiftUI view, in a target with no tests: the height budget subtracted one
/// 44-point bar, the footer consumed it, and nothing at all was reserved for the
/// top bar — so every page drew its first lines underneath an opaque toolbar.
@Suite("Reserving room for the reader's own chrome")
struct ReaderChromeTests {
    /// A Dynamic Island iPhone with the shipped margin.
    static let phone = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24)
    static let window = CGSize(width: 402, height: 874)

    @Test("text never begins underneath the top bar")
    func textClearsTheTopBar() {
        // The whole defect, as one assertion. Against the old inline arithmetic
        // the first line began at safeAreaTop + margin = 83, while the bar
        // reached 103.
        #expect(Self.phone.topReserve >= Self.phone.safeAreaTop + ReaderChrome.barHeight)
    }

    @Test("text never ends underneath the footer")
    func textClearsTheFooter() {
        #expect(Self.phone.bottomReserve >= Self.phone.safeAreaBottom + ReaderChrome.barHeight)
    }

    @Test("the reserves and the page exactly fill the window")
    func reservesAndPageFillTheWindow() {
        let size = Self.phone.pageSize(in: Self.window)
        // Nothing unaccounted for: an over-count leaves a gap the reader reads
        // as wasted space, an under-count puts text behind a bar.
        #expect(Self.phone.topReserve + size.height + Self.phone.bottomReserve == Self.window.height)
        #expect(size.width + Self.phone.margin * 2 == Self.window.width)
    }

    @Test("the top bar absorbs the page's top margin rather than stacking with it")
    func barAbsorbsTheTopMargin() {
        // 44 points of empty bar is already more room than the margin gave, and
        // adding both is how the screen ends up mostly blank.
        #expect(Self.phone.topReserve == Self.phone.safeAreaTop + ReaderChrome.barHeight)
        #expect(Self.phone.topReserve < Self.phone.safeAreaTop + ReaderChrome.barHeight + Self.phone.margin)
    }

    @Test("a bigger margin takes width from the page, not from the chrome")
    func marginAffectsWidthNotTopReserve() {
        let wide = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 48)
        #expect(wide.topReserve == Self.phone.topReserve)
        #expect(wide.pageSize(in: Self.window).width < Self.phone.pageSize(in: Self.window).width)
    }

    @Test("a device with no unsafe edges still reserves both bars")
    func noSafeAreaStillReservesBars() {
        // The Mac, and the zero-inset first layout pass before the window has
        // been measured — which must not lay text out into the bars either.
        let flat = ReaderChrome(safeAreaTop: 0, safeAreaBottom: 0, margin: 24)
        #expect(flat.topReserve == ReaderChrome.barHeight)
        #expect(flat.bottomReserve == ReaderChrome.barHeight + 24)
    }

    @Test("the Mac's rounded corner is reserved like any other unsafe edge")
    func macCornerIsReserved() {
        // The Mac has no notch and no home indicator, so `ReaderInsets` handed
        // it nothing at all — and the footer, being the last thing in the
        // reader's stack, ended exactly at the window's bottom edge with the
        // play button, the chapter title and the percentage sitting inside the
        // corner radius.
        //
        // The fix is an inset, and the reason it belongs in `ReaderInsets`
        // rather than as a padding on the footer is this second assertion: the
        // page's budget has to shrink by exactly as much as the footer moves
        // up, or the last line is pushed under the bar instead of clearing it.
        let mac = ReaderChrome(safeAreaTop: 0, safeAreaBottom: 14, margin: 24)
        let flat = ReaderChrome(safeAreaTop: 0, safeAreaBottom: 0, margin: 24)

        #expect(mac.bottomReserve == flat.bottomReserve + 14)
        #expect(mac.topReserve == flat.topReserve, "the titlebar is AppKit's business, not ours")
        #expect(
            mac.pageSize(in: Self.window).height == flat.pageSize(in: Self.window).height - 14)
    }

    @Test("negative insets cannot shrink the reserve")
    func negativeInsetsAreClamped() {
        let odd = ReaderChrome(safeAreaTop: -20, safeAreaBottom: -5, margin: -10)
        #expect(odd.topReserve == ReaderChrome.barHeight)
        #expect(odd.bottomReserve == ReaderChrome.barHeight)
    }

    @Test("a window too short to hold the chrome still yields a usable size")
    func tinyWindowIsClamped() {
        let tiny = CGSize(width: 10, height: 10)
        let size = Self.phone.pageSize(in: tiny)
        // Handed straight to TextKit, which lays out nothing at all given a
        // negative box.
        #expect(size.width >= 1)
        #expect(size.height >= 1)
        #expect(Self.phone.fits(tiny) == false)
        #expect(Self.phone.fits(Self.window))
    }

    @Test("the page size depends on nothing that a chrome toggle changes")
    func stableAcrossChromeToggles() {
        // There is deliberately no visibility input. This test is the record of
        // that: the page moved on every tap when the layout was measured against
        // the live safe area, and the fix was to measure the window instead.
        let before = Self.phone.pageSize(in: Self.window)
        let after = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24)
            .pageSize(in: Self.window)
        #expect(before == after)
    }
}
