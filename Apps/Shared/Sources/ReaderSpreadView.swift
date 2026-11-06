import IssaRender
import IssaUI
import SwiftUI

/// Two pages of the chapter side by side, either side of the fold: iPhone
/// Duo's inner display held wide (`ReaderLayout.Spread`).
///
/// The same `PageSurface`s the page track draws, from the same chapter
/// layout, so a spread is two pages of the pagination every other device
/// has, not a second one. It has no turn of its own: a spread turns at once
/// (`PageTurn.effectiveStyle(_:reduceMotion:spread:)`).
struct ReaderSpreadView: View {
    let model: ReaderModel
    let pageSize: CGSize
    /// Where the two text boxes begin, in this view's coordinates.
    let leftX: CGFloat
    let rightX: CGFloat
    let width: CGFloat
    let insets: EdgeInsets

    var body: some View {
        // Read in the body, as the page track reads its own, so a page change
        // or a highlight redraws both.
        let left = model.currentSnapshot()
        let right = model.facingSnapshot()
        ZStack(alignment: .topLeading) {
            model.style.theme.background
            if let left {
                PageSurface(left, size: pageSize)
                    .equatable()
                    .offset(x: leftX, y: insets.top)
            }
            if let right {
                PageSurface(right, size: pageSize)
                    .equatable()
                    .offset(x: rightX, y: insets.top)
            }
        }
        .frame(width: width, height: pageSize.height + insets.top + insets.bottom, alignment: .topLeading)
        // Pages are physical, as the track's are: the left one is the first.
        .environment(\.layoutDirection, .leftToRight)
        .clipped()
    }
}

/// What the chapter is laid out for: the size of a page, and how many stand
/// side by side. A change in either lays it out again.
struct PageGeometry: Equatable {
    let size: CGSize
    let pagesShown: Int
}
