import IssaRender
import IssaUI
import SwiftUI

/// One page, as plain values: everything `PageSurface` draws it from.
///
/// What lets a page keep drawing after the model has moved on. A turn commits
/// first and animates after, so the page sliding away is no longer the model's
/// page by the time it moves — it is this, taken just before.
struct PageSnapshot: Equatable {
    let layout: ChapterLayout
    let page: RenderedPage
    let activeFragment: String?
    let annotations: [PageSurface.AnnotationBlock]
    let selection: NSRange?
    let theme: ReaderTheme
    let highlight: Color
    let highlightStyle: HighlightBlock.Style

    /// The layout by identity: it is a class, re-paginated in place, and two
    /// snapshots of different layouts are different pages whatever their
    /// numbers say.
    static func == (lhs: PageSnapshot, rhs: PageSnapshot) -> Bool {
        lhs.layout === rhs.layout && lhs.page == rhs.page
            && lhs.activeFragment == rhs.activeFragment && lhs.annotations == rhs.annotations
            && lhs.selection == rhs.selection && lhs.theme == rhs.theme
            && lhs.highlight == rhs.highlight && lhs.highlightStyle == rhs.highlightStyle
    }
}

/// What turning one page that way would show.
enum NeighbourPreview: Equatable {
    case page(PageSnapshot)
    /// The next chapter is still being read: a blank page in the paper's
    /// colour follows the finger until it arrives.
    case pending
    /// Nothing that way — the first or last page of the book.
    case none
}

/// The page, and the page it is turning to.
///
/// The outer view reads the model, which is how the live page follows the
/// narration as it always has; the layer inside reads only the turner, so a
/// finger moving the page re-evaluates offsets and nothing else.
///
/// The caller makes it one accessibility element with `PageAccessibility`,
/// outside the motion, saying what the model says: the page being turned to is
/// the page the moment the turn is made, and the one sliding away is not there
/// at all. Outside rather than in here so the television can put it where it
/// always was, around the focusable page.
struct PageTrackView: View {
    let model: ReaderModel
    let turner: PageTurner
    /// The page's own size, inside its margins.
    let pageSize: CGSize
    /// The margins each page is drawn inside. A page slides with its margins,
    /// so the whole width of the reader travels and no text is ever cut by a
    /// stationary edge.
    let insets: EdgeInsets

    var body: some View {
        // Read in the body, not inside the renderer closure — observation tracks
        // what a body touches.
        PageTrackLayer(
            turner: turner,
            live: model.currentSnapshot(),
            paper: model.style.theme.background,
            pageSize: pageSize,
            insets: insets,
        )
    }
}

private struct PageTrackLayer: View {
    let turner: PageTurner
    let live: PageSnapshot?
    let paper: Color
    let pageSize: CGSize
    let insets: EdgeInsets

    private var width: CGFloat { pageSize.width + insets.leading + insets.trailing }
    private var height: CGFloat { pageSize.height + insets.top + insets.bottom }

    var body: some View {
        TimelineView(.animation(paused: turner.motion == nil)) { context in
            let scene = turner.scene
            let placement = scene.map {
                PageTurn.placement(
                    style: turner.style, direction: $0.direction,
                    progress: turner.progress(at: context.date.timeIntervalSinceReferenceDate),
                    width: width)
            }
            let liveArrives = scene?.liveIsArriving ?? false
            let liveX = placement.map { liveArrives ? $0.arrivingX : $0.leavingX } ?? 0
            let otherX = placement.map { liveArrives ? $0.leavingX : $0.arrivingX } ?? 0
            let liveOnTop = placement.map { liveArrives == $0.arrivingOnTop } ?? true

            ZStack(alignment: .topLeading) {
                // Always here, and always first: the page on screen keeps one
                // identity from rest, through the turn, to rest again, so its
                // canvas is never torn down and redrawn when a turn ends.
                slot(live)
                    .offset(x: liveX)
                    .zIndex(liveOnTop ? 2 : 0)
                if let scene {
                    switch scene.other {
                    case let .page(snapshot): slot(snapshot).offset(x: otherX).zIndex(liveOnTop ? 0 : 2)
                    case .blank: blank.offset(x: otherX).zIndex(liveOnTop ? 0 : 2)
                    }
                }
                if let placement, placement.shadowOpacity > 0 {
                    LinearGradient(
                        colors: [.black.opacity(placement.shadowOpacity), .black.opacity(0)],
                        startPoint: .leading, endPoint: .trailing,
                    )
                    .frame(width: PageTurn.shadowWidth, height: height)
                    .offset(x: placement.shadowX)
                    .zIndex(1)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: height, alignment: .topLeading)
            // Turns are physical: forward is the page moving left whatever the
            // language of the interface around it.
            .environment(\.layoutDirection, .leftToRight)
            .clipped()
        }
        // The turner moves the page by its own clock. Nothing above — the
        // chrome's fade, the chapter notice — may animate it as well.
        .transaction { $0.animation = nil }
    }

    @ViewBuilder
    private func slot(_ snapshot: PageSnapshot?) -> some View {
        if let snapshot {
            PageSurface(snapshot, size: pageSize)
                .equatable()
                .padding(insets)
                .background(paper)
        } else {
            // The chapter is still being laid out. Holding the page's exact
            // size means nothing above or below it moves when the glyphs
            // arrive, which is the whole reason the reserve exists.
            blank
        }
    }

    private var blank: some View {
        paper.frame(width: width, height: height)
    }
}
