import CoreGraphics
import Foundation
import Testing

@testable import IssaUI

/// The rule that decides the iPhone Duo's layouts, and that nothing else
/// reaches them.
@Suite("Laying out for a display that folds")
struct AdaptiveLayoutTests {
    typealias Region = AdaptiveLayout.Region

    /// The Duo's inner display held wide: 951 by 669, its fold down the middle.
    static let innerWide = CGRect(x: 0, y: 0, width: 951, height: 669)
    static let openFold = Region(frame: CGRect(x: 463, y: 0, width: 25, height: 669), isActive: false)
    static let bookFold = Region(frame: CGRect(x: 451, y: 0, width: 49, height: 669), isActive: true)
    static let tableFold = Region(frame: CGRect(x: 0, y: 310, width: 951, height: 48), isActive: true)

    @Test("expanded only when both size classes are regular")
    func expandedNeedsBothRegular() {
        let classes: [AdaptiveLayout.SizeClass?] = [nil, .compact, .regular]
        for horizontal in classes {
            for vertical in classes {
                let expected: AdaptiveLayout.Mode =
                    horizontal == .regular && vertical == .regular ? .expanded : .standard
                #expect(AdaptiveLayout.mode(horizontal: horizontal, vertical: vertical) == expected)
            }
        }
    }

    @Test("no fold in force is flat, whether there is a fold or not")
    func flatWithoutAnActiveFold() {
        #expect(AdaptiveLayout.pose(folds: []) == .flat)
        #expect(AdaptiveLayout.pose(folds: [Self.openFold]) == .flat)
    }

    @Test("a vertical fold in force is the book pose, a horizontal one the table")
    func poseFromTheFold() {
        #expect(AdaptiveLayout.pose(folds: [Self.bookFold]) == .book)
        #expect(AdaptiveLayout.pose(folds: [Self.tableFold]) == .table)
        #expect(AdaptiveLayout.pose(folds: [Self.openFold, Self.tableFold]) == .table)
    }

    @Test("the dividing fold is a vertical one, active or not, inside the bounds")
    func verticalFold() {
        #expect(AdaptiveLayout.verticalFold(in: [Self.openFold], bounds: Self.innerWide) == Self.openFold)
        #expect(AdaptiveLayout.verticalFold(in: [Self.tableFold], bounds: Self.innerWide) == nil)
        #expect(AdaptiveLayout.verticalFold(in: [], bounds: Self.innerWide) == nil)
        let elsewhere = CGRect(x: 1_000, y: 0, width: 400, height: 669)
        #expect(AdaptiveLayout.verticalFold(in: [Self.openFold], bounds: elsewhere) == nil)
    }

    @Test("content keeps clear of a fold in force, and only of one in force")
    func foldClearance() {
        let bounds = Self.innerWide
        #expect(AdaptiveLayout.foldClearance(folds: [], in: bounds) == .zero)
        #expect(AdaptiveLayout.foldClearance(folds: [Self.openFold], in: bounds) == .zero)
        // A book fold sends the content to the trailing pane.
        #expect(AdaptiveLayout.foldClearance(folds: [Self.bookFold], in: bounds)
            == AdaptiveLayout.Insets(leading: 500))
        // A table fold sends it to the flat half below.
        #expect(AdaptiveLayout.foldClearance(folds: [Self.tableFold], in: bounds)
            == AdaptiveLayout.Insets(top: 358))
        // A fold that misses the content moves nothing.
        let elsewhere = CGRect(x: 600, y: 0, width: 351, height: 669)
        #expect(AdaptiveLayout.foldClearance(folds: [Self.bookFold], in: elsewhere) == .zero)
    }

    @Test("signals default to saying nothing")
    func defaultSignalsAreSilent() {
        let signals = AdaptiveLayout.Signals()
        #expect(signals.bars == .top)
        #expect(signals.folds.isEmpty)
        #expect(signals.horizontal == nil && signals.vertical == nil)
    }
}
