import CoreGraphics
import Foundation
import IssaUI
import Testing

@testable import IssaRender

/// Where the reader's tools and pages go on iPhone Duo, and that nothing
/// moves anywhere else.
@Suite("The reader's layout on a display that folds")
struct ReaderLayoutTests {
    typealias Region = AdaptiveLayout.Region

    /// The outer display as the simulator reports it: 466 by 678, the bars and
    /// an 84-point unsafe band down the trailing side, the sensor bar at its
    /// top.
    static let outer = CGSize(width: 466, height: 678)
    static let outerInsets = AdaptiveLayout.Insets(top: 0, leading: 0, bottom: 34, trailing: 84)
    static let outerSignals = AdaptiveLayout.Signals(
        horizontal: .compact, vertical: .regular, bars: .trailing,
        occlusions: [
            Region(frame: CGRect(x: 399, y: 29, width: 37, height: 37), isActive: true),
            Region(frame: CGRect(x: 382, y: 0, width: 84, height: 170), isActive: true),
        ])

    /// The inner display held wide, with the rail of the design: 951 by 669.
    static let inner = CGSize(width: 951, height: 669)
    static let innerInsets = AdaptiveLayout.Insets(top: 0, leading: 0, bottom: 20, trailing: 60)
    static func innerSignals(folds: [Region] = []) -> AdaptiveLayout.Signals {
        AdaptiveLayout.Signals(horizontal: .regular, vertical: .regular, bars: .trailing, folds: folds)
    }

    @Test("with nothing said, the layout is the one every other device has")
    func silentSignalsAreStandard() {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 1180, height: 820), Self.inner] {
            let layout = ReaderLayout.resolve(
                .none, window: size, insets: AdaptiveLayout.Insets(top: 59, bottom: 34), margin: 24)
            #expect(layout == .standard)
            #expect(layout.railWidth == 0)
            #expect(layout.pagesShown == 1)
        }
    }

    @Test("an iPad, regular both ways but with its bars on top and no fold, keeps one page")
    func iPadKeepsOnePage() {
        let signals = AdaptiveLayout.Signals(horizontal: .regular, vertical: .regular)
        let layout = ReaderLayout.resolve(
            signals, window: CGSize(width: 1180, height: 820),
            insets: AdaptiveLayout.Insets(top: 24, bottom: 20), margin: 24)
        #expect(layout == .standard)
    }

    @Test("bars down a side put the tools in a rail as wide as the unsafe band, below the sensor bar")
    func outerDisplayRail() {
        let layout = ReaderLayout.resolve(
            Self.outerSignals, window: Self.outer, insets: Self.outerInsets, margin: 24)
        #expect(layout.tools == .rail(side: .trailing, width: 84, top: 170))
        #expect(layout.spread == nil, "the outer display is compact: one page")
    }

    @Test("a rail with nothing to say about the sensor bar starts below the safe top")
    func railWithoutOcclusion() {
        var signals = Self.outerSignals
        signals.occlusions = []
        let layout = ReaderLayout.resolve(
            signals, window: Self.outer, insets: AdaptiveLayout.Insets(top: 12, trailing: 84), margin: 24)
        #expect(layout.tools == .rail(side: .trailing, width: 84, top: 12))
    }

    @Test("the inner display held wide is a spread mirrored around the fold")
    func innerSpreadAroundTheFold() throws {
        let fold = Region(frame: CGRect(x: 463, y: 0, width: 25, height: 669), isActive: false)
        let layout = ReaderLayout.resolve(
            Self.innerSignals(folds: [fold]), window: Self.inner, insets: Self.innerInsets, margin: 24)
        let spread = try #require(layout.spread)
        // The design's numbers: two 367-point pages, 24 clear of the fold's
        // centre at 475.5, the right one ending a margin short of the rail.
        #expect(spread.divider == 475.5)
        #expect(spread.pageWidth == 367)
        #expect(spread.rightX == 499.5)
        #expect(spread.leftX + spread.pageWidth == 451.5)
        #expect(layout.pagesShown == 2)
    }

    @Test("with no fold named, the spread divides the window where the hinge is")
    func innerSpreadWithoutAFoldRegion() throws {
        let layout = ReaderLayout.resolve(
            Self.innerSignals(), window: Self.inner, insets: Self.innerInsets, margin: 24)
        let spread = try #require(layout.spread)
        #expect(spread.divider == 475.5)
        #expect(spread.divider - spread.leftX - spread.pageWidth == ReaderLayout.foldClearance)
        #expect(spread.rightX - spread.divider == ReaderLayout.foldClearance)
    }

    @Test("a fold wider than the clearance pushes both pages out to clear it")
    func wideFoldWidensTheGap() throws {
        let fold = Region(frame: CGRect(x: 445.5, y: 0, width: 60, height: 669), isActive: true)
        let layout = ReaderLayout.resolve(
            Self.innerSignals(folds: [fold]), window: Self.inner, insets: Self.innerInsets, margin: 24)
        let spread = try #require(layout.spread)
        #expect(spread.rightX - spread.divider == 30)
        #expect(layout.pose == .book)
    }

    @Test("a window too narrow for two good pages keeps one")
    func narrowWindowKeepsOnePage() {
        let layout = ReaderLayout.resolve(
            Self.innerSignals(), window: CGSize(width: 700, height: 669),
            insets: Self.innerInsets, margin: 24)
        #expect(layout.spread == nil)
    }

    @Test("held tall, with the fold across the middle, the inner display keeps one page")
    func tallInnerKeepsOnePage() {
        let fold = Region(frame: CGRect(x: 0, y: 463, width: 669, height: 25), isActive: false)
        let signals = AdaptiveLayout.Signals(
            horizontal: .regular, vertical: .regular, bars: .top, folds: [fold])
        let layout = ReaderLayout.resolve(
            signals, window: CGSize(width: 669, height: 951),
            insets: AdaptiveLayout.Insets(top: 30, bottom: 20), margin: 24)
        #expect(layout == .standard)
    }

    @Test("the footer counts one page, or the two of a spread")
    func pageNumbering() {
        #expect(PageNumbering.text(first: 6, shown: 1, count: 114) == "6 / 114")
        #expect(PageNumbering.text(first: 6, shown: 2, count: 114) == "6–7 / 114")
        #expect(PageNumbering.text(first: 114, shown: 2, count: 114) == "114 / 114")
    }

    @Test("propped open like a laptop, the rail's tools move below the fold")
    func tablePoseMovesTheRailDown() throws {
        let fold = Region(frame: CGRect(x: 0, y: 310, width: 951, height: 48), isActive: true)
        let layout = ReaderLayout.resolve(
            Self.innerSignals(folds: [fold]), window: Self.inner, insets: Self.innerInsets, margin: 24)
        #expect(layout.pose == .table)
        #expect(layout.tools == .rail(side: .trailing, width: 60, top: 358))
        #expect(layout.spread == nil, "a horizontal fold divides nothing side by side")
        #expect(ReaderLayout.tableFold(Self.innerSignals(folds: [fold])) == fold.frame)
        #expect(ReaderLayout.tableFold(Self.innerSignals()) == nil)
    }

    @Test("the rail stays where it was when the status bar goes with the chrome")
    func railTopIsHeld() {
        let shown = ReaderLayout(tools: .rail(side: .trailing, width: 84, top: 170), spread: nil, pose: .flat)
        let hidden = ReaderLayout(tools: .rail(side: .trailing, width: 84, top: 82), spread: nil, pose: .flat)
        #expect(hidden.keepingRailTop(of: shown).tools == shown.tools)
        #expect(shown.keepingRailTop(of: hidden).tools == shown.tools, "a lower top is taken as it comes")
        let rotated = ReaderLayout(tools: .rail(side: .trailing, width: 60, top: 40), spread: nil, pose: .flat)
        #expect(rotated.keepingRailTop(of: shown) == rotated, "a new window starts again")
        #expect(ReaderLayout.standard.keepingRailTop(of: shown) == .standard)
    }

    @Test("regions read in another window are not this one's")
    func staleRegionsAreIgnored() {
        // The inner display's fold, still published a moment after closing.
        let fold = Region(frame: CGRect(x: 0, y: 310, width: 951, height: 48), isActive: true)
        var signals = Self.outerSignals
        signals.folds = [fold]
        signals.window = Self.inner
        let layout = ReaderLayout.resolve(signals, window: Self.outer, insets: Self.outerInsets, margin: 24)
        #expect(layout.pose == .flat)
        #expect(layout.tools == .rail(side: .trailing, width: 84, top: 0))
        // Read in this window, they count.
        signals.window = Self.outer
        signals.folds = []
        let settled = ReaderLayout.resolve(signals, window: Self.outer, insets: Self.outerInsets, margin: 24)
        #expect(settled.tools == .rail(side: .trailing, width: 84, top: 170))
    }

    @Test("a rail's top from another pose is not held")
    func railTopIsNotHeldAcrossPoses() {
        let table = ReaderLayout(tools: .rail(side: .trailing, width: 84, top: 358), spread: nil, pose: .table)
        let flat = ReaderLayout(tools: .rail(side: .trailing, width: 84, top: 170), spread: nil, pose: .flat)
        #expect(flat.keepingRailTop(of: table) == flat)
    }
}
