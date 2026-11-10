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

    @Test("a real toolbar replaces the in-page bar but not the page's top margin")
    func macToolbarIsTheToolbarPlusTheMargin() {
        // The Mac draws no bar over the page — it has a window toolbar — and
        // the first correction was to stop reserving 44 points for a bar that
        // is not there. But it went one step too far and reserved the toolbar
        // and nothing else, so the first line sat flush against the toolbar
        // with no air above it at all and its ascenders shaved by the canvas's
        // clip. The margin the other three edges get is not one the top can go
        // without: it is only ever waived because a 44-point bar is already
        // standing in that space.
        let mac = ReaderChrome(safeAreaTop: 52, safeAreaBottom: 14, margin: 24, drawsOwnTopBar: false)
        #expect(mac.topReserve == mac.safeAreaTop + mac.margin)
        #expect(mac.topReserve == 76, "a 52-point toolbar and the shipped 24-point margin")

        // Still the assertion that matters most: the page never begins above
        // the toolbar, which is where the whole fault started.
        #expect(mac.topReserve >= mac.safeAreaTop)

        // And it is cheaper than the in-page bar it replaces, so the Mac is not
        // simply paying twice.
        let flat = ReaderChrome(safeAreaTop: 52, safeAreaBottom: 14, margin: 24)
        #expect(mac.topReserve < flat.topReserve)

        let phone = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24)
        #expect(phone.topReserve == 59 + ReaderChrome.barHeight, "unchanged off the Mac")
    }

    @Test("the reserves still exactly fill the window when there is no in-page top bar")
    func macReservesAndPageFillTheWindow() {
        let mac = ReaderChrome(safeAreaTop: 52, safeAreaBottom: 14, margin: 24, drawsOwnTopBar: false)
        let size = mac.pageSize(in: Self.window)
        // The same invariant the phone is held to: nothing unaccounted for in
        // either direction. An under-count here is text under the toolbar, and
        // a reserve the view does not also draw is the same thing — the top
        // margin is taken out of the budget here and put on screen by
        // `ReaderView`, and the two have to be the same number.
        #expect(mac.topReserve + size.height + mac.bottomReserve == Self.window.height)
        #expect(size.width + mac.margin * 2 == Self.window.width)
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

    // MARK: - A rail down the side (iPhone Duo)

    @Test("without a rail, every number is the one 1.5.2 used")
    func noRailIsUnchanged() {
        let plain = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24)
        let zero = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24, railWidth: 0)
        #expect(plain == zero)
        #expect(plain.drawsOwnTopBar)
        #expect(plain.topReserve == 59 + ReaderChrome.barHeight)
        #expect(plain.pageSize(in: Self.window) == CGSize(width: 402 - 48, height: 874 - 103 - 102))
    }

    @Test("a rail takes its band out of the width and the top bar's place at the top")
    func railTakesTheSide() {
        let rail = ReaderChrome(safeAreaTop: 0, safeAreaBottom: 34, margin: 24, railWidth: 84)
        let window = CGSize(width: 466, height: 678)
        #expect(!rail.drawsOwnTopBar, "the tools are in the rail, not across the top")
        #expect(rail.topReserve == 24, "the margin is spent at the top, as on the Mac")
        let size = rail.pageSize(in: window)
        #expect(size.width == window.width - 84 - 48)
        #expect(rail.topReserve + size.height + rail.bottomReserve == window.height)
        #expect(rail.fits(window))
    }

    // MARK: Filling the screen

    @Test("filling the screen gives both bars' bands to the page")
    func fillGivesBothBands() {
        let fill = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24, fillsScreen: true)
        #expect(fill.topReserve == CGFloat(59 + 24))
        #expect(fill.bottomReserve == CGFloat(34 + 24))
        // The bottom band comes back whole; the top bar's stood in for the
        // margin, so only what exceeded the margin does.
        #expect(
            fill.pageSize(in: Self.window).height - Self.phone.pageSize(in: Self.window).height
                == (ReaderChrome.barHeight - 24) + ReaderChrome.barHeight)
        #expect(fill.pageSize(in: Self.window).width == Self.phone.pageSize(in: Self.window).width)
        #expect(fill.topReserve + fill.pageSize(in: Self.window).height + fill.bottomReserve == Self.window.height)
    }

    @Test("where the bar is not the page's, only the footer's band is given back")
    func fillOnTheMacAndTheRail() {
        let mac = ReaderChrome(safeAreaTop: 52, safeAreaBottom: 14, margin: 24, drawsOwnTopBar: false)
        let macFill = ReaderChrome(
            safeAreaTop: 52, safeAreaBottom: 14, margin: 24, drawsOwnTopBar: false, fillsScreen: true)
        #expect(macFill.topReserve == mac.topReserve)
        #expect(
            macFill.pageSize(in: Self.window).height
                == mac.pageSize(in: Self.window).height + ReaderChrome.barHeight)

        let rail = ReaderChrome(safeAreaTop: 20, safeAreaBottom: 0, margin: 24, railWidth: 84)
        let railFill = ReaderChrome(
            safeAreaTop: 20, safeAreaBottom: 0, margin: 24, railWidth: 84, fillsScreen: true)
        #expect(railFill.topReserve == rail.topReserve)
        #expect(
            railFill.pageSize(in: Self.window).height
                == rail.pageSize(in: Self.window).height + ReaderChrome.barHeight)
        #expect(railFill.pageSize(in: Self.window).width == rail.pageSize(in: Self.window).width)
    }

    @Test("the hardware's edges stay kept when the page fills the screen")
    func fillKeepsTheSafeAreas() {
        let fill = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 0, fillsScreen: true)
        #expect(fill.topReserve == 59)
        #expect(fill.bottomReserve == 34)
    }

    @Test("filling the screen is off by default")
    func fillIsOffByDefault() {
        #expect(!Self.phone.fillsScreen)
    }

    @Test("a window too short for the chrome fits once the chrome is not reserved")
    func fillFits() {
        let short = CGSize(width: 402, height: 59 + 34 + 2 * ReaderChrome.barHeight + 24 * 2 + 10)
        #expect(!Self.phone.fits(CGSize(width: 402, height: 59 + 34 + 2 * ReaderChrome.barHeight + 24)))
        let fill = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24, fillsScreen: true)
        #expect(fill.fits(short))
        #expect(fill.fits(CGSize(width: 402, height: 59 + 34 + 24 * 2 + 1)))
    }

    // MARK: Top and bottom margin

    @Test("the vertical margin replaces the side margin at the top and bottom only")
    func verticalMarginIsItsOwn() {
        let fill = ReaderChrome(
            safeAreaTop: 59, safeAreaBottom: 34, margin: 24, fillsScreen: true, verticalMargin: 0)
        #expect(fill.topReserve == 59)
        #expect(fill.bottomReserve == 34)
        #expect(fill.pageSize(in: Self.window).width == CGFloat(402 - 48))
        let wide = ReaderChrome(
            safeAreaTop: 59, safeAreaBottom: 34, margin: 24, fillsScreen: true, verticalMargin: 64)
        #expect(wide.topReserve == CGFloat(59 + 64))
        #expect(wide.bottomReserve == CGFloat(34 + 64))
        #expect(wide.pageSize(in: Self.window).width == CGFloat(402 - 48))
    }

    @Test("without filling the screen the vertical margin changes nothing")
    func verticalMarginNeedsFill() {
        let plain = ReaderChrome(safeAreaTop: 59, safeAreaBottom: 34, margin: 24, verticalMargin: 0)
        #expect(plain.topReserve == Self.phone.topReserve)
        #expect(plain.bottomReserve == Self.phone.bottomReserve)
    }

    // MARK: Text part-way into the safe areas

    static let island = CGSize(width: 402, height: 874)

    @Test("an island phone gives the text its safe area back down to the sensor and the indicator")
    func islandPhone() throws {
        let edges = try #require(FillEdges.iPhone(safeAreaTop: 62, safeAreaBottom: 34))
        let fill = ReaderChrome(
            safeAreaTop: 62, safeAreaBottom: 34, margin: 16, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        #expect(abs(fill.topReserve - 53.6) < 0.01)
        // The 16-point corner governs the bottom: deeper than the 18-point
        // indicator clearance.
        #expect(abs(fill.bottomReserve - 22.3) < 0.1)
        #expect(fill.topReserve + fill.pageSize(in: Self.island).height + fill.bottomReserve == 874)
    }

    @Test("the indicator clearance governs where the corner is shallower")
    func standardMargin() throws {
        let edges = try #require(FillEdges.iPhone(safeAreaTop: 62, safeAreaBottom: 34))
        let fill = ReaderChrome(
            safeAreaTop: 62, safeAreaBottom: 34, margin: 24, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        #expect(fill.bottomReserve == 18)
        #expect(abs(fill.topReserve - 53.6) < 0.01)
    }

    @Test("a notch phone keeps clear of its shorter housing")
    func notchPhone() throws {
        let edges = try #require(FillEdges.iPhone(safeAreaTop: 47, safeAreaBottom: 34))
        let fill = ReaderChrome(
            safeAreaTop: 47, safeAreaBottom: 34, margin: 24, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        #expect(abs(fill.topReserve - 41.6) < 0.01)
    }

    @Test("an Edge margin keeps the whole bottom safe area, the corner being that deep")
    func edgeMargin() throws {
        let edges = try #require(FillEdges.iPhone(safeAreaTop: 62, safeAreaBottom: 34))
        let fill = ReaderChrome(
            safeAreaTop: 62, safeAreaBottom: 34, margin: 4, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        #expect(fill.hardwareBottom == 34)
        #expect(abs(fill.hardwareTop - 53.6) < 0.01, "the corner at 44.4 is shallower than the sensor's reach")
    }

    @Test("the safe area is a ceiling: nothing is ever added")
    func neverGrows() {
        let edges = FillEdges(sensorClearance: 54, indicatorClearance: 18)
        let small = ReaderChrome(
            safeAreaTop: 20, safeAreaBottom: 10, margin: 4, fillsScreen: true, fillEdges: edges)
        #expect(small.hardwareTop == 20)
        #expect(small.hardwareBottom == 10)
    }

    @Test("without fill, or without edges, the safe areas are whole")
    func edgesNeedFillAndKnowledge() {
        let edges = FillEdges(sensorClearance: 54, indicatorClearance: 18)
        let notFilling = ReaderChrome(safeAreaTop: 62, safeAreaBottom: 34, margin: 24, fillEdges: edges)
        #expect(notFilling.topReserve == CGFloat(62 + 44))
        #expect(notFilling.bottomReserve == CGFloat(34 + 44 + 24))
        let unknown = ReaderChrome(safeAreaTop: 62, safeAreaBottom: 34, margin: 24, fillsScreen: true)
        #expect(unknown.topReserve == CGFloat(62 + 24))
        #expect(unknown.bottomReserve == CGFloat(34 + 24))
    }

    @Test("edges are only built for a phone with a housing and an indicator")
    func edgesAreConditional() throws {
        #expect(FillEdges.iPhone(safeAreaTop: 20, safeAreaBottom: 0) == nil)
        #expect(FillEdges.iPhone(safeAreaTop: 24, safeAreaBottom: 34) == nil)
        #expect(FillEdges.iPhone(safeAreaTop: 47, safeAreaBottom: 0) == nil)
        func clearance(_ top: CGFloat) -> CGFloat? {
            FillEdges.iPhone(safeAreaTop: top, safeAreaBottom: 34)?.sensorClearance
        }
        #expect(abs(try #require(clearance(62)) - 53.6) < 0.01)
        #expect(abs(try #require(clearance(59)) - 51.2) < 0.01)
        #expect(abs(try #require(clearance(50)) - 44) < 0.01)
        #expect(abs(try #require(clearance(47)) - 41.6) < 0.01)
        // A zoomed 17 Pro: a smaller safe top, a proportionally smaller island.
        #expect(abs(try #require(clearance(57.8)) - 50.24) < 0.01)
    }

    @Test("showing or hiding the chrome has no input into any reserve")
    func reservesAreConstant() {
        // The chrome's visibility is not a parameter at all; two chromes built
        // from the same window are the same value, which is what keeps a tap
        // from re-paginating.
        let edges = FillEdges.iPhone(safeAreaTop: 62, safeAreaBottom: 34)
        let a = ReaderChrome(
            safeAreaTop: 62, safeAreaBottom: 34, margin: 16, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        let b = ReaderChrome(
            safeAreaTop: 62, safeAreaBottom: 34, margin: 16, fillsScreen: true,
            verticalMargin: 0, fillEdges: edges)
        #expect(a == b)
        #expect(a.pageSize(in: Self.island) == b.pageSize(in: Self.island))
    }

    @Test("the corner table only ever gets shallower with depth")
    func cornerTableIsMonotonic() {
        let table = ScreenCorner.iPhone.envelope
        for (a, b) in zip(table, table.dropFirst()) {
            #expect(b.depth > a.depth)
            #expect(b.cutIn < a.cutIn)
        }
    }

    @Test("the corner's depth for an inset interpolates the table")
    func cornerDepth() {
        let corner = ScreenCorner.iPhone
        #expect(abs(corner.depth(forInset: 16) - 22.3) < 0.05)
        #expect(abs(corner.depth(forInset: 24) - 14.5) < 0.1)
        #expect(abs(corner.depth(forInset: 4) - 44.4) < 0.1)
        #expect(corner.depth(forInset: 77) == 0)
        #expect(corner.depth(forInset: 200) == 0)
        #expect(corner.depth(forInset: 0) == 80)
        #expect(corner.depth(forInset: -5) == 80)
        #expect(corner.depth(forInset: 18) == 20)
        var last = CGFloat.infinity
        for inset in stride(from: CGFloat(0), through: 80, by: 1) {
            let depth = corner.depth(forInset: inset)
            #expect(depth <= last)
            last = depth
        }
    }
}
