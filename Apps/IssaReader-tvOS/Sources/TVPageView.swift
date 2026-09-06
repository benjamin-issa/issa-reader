import IssaRender
import IssaUI
import SwiftUI

/// What the remote is pointing at.
enum TVFocus: Hashable {
    case page
    case transport
}

/// One page of the book on a television, and the remote that turns it.
///
/// The page is drawn by `PageSurface` — the same view the phone and the Mac
/// use, so the read-along block, the stored highlights and the glyphs are
/// identical here — and everything this view adds is about the remote: which
/// direction turns a page, where focus goes, and how one page becomes the next.
struct TVPageView: View {
    let model: ReaderModel
    let size: CGSize
    @FocusState.Binding var focus: TVFocus?

    /// Which way the last turn went, so the outgoing page leaves the way a
    /// paper page would.
    @State private var forward = true
    /// One turn at a time.
    ///
    /// A held-down remote repeats, and `turnPage` is asynchronous — it may load
    /// a chapter and seek audio. Without this, three presses in a second start
    /// three overlapping turns, each one having read `pageIndex` before the
    /// others committed, and the book arrives somewhere none of them meant.
    @State private var turning = false

    /// Which page is on screen, as far as the animation is concerned.
    ///
    /// Chapter *and* page: page 0 of chapter 2 is not page 0 of chapter 1, and
    /// keying on the page number alone would cross a chapter boundary with no
    /// transition at all — the one moment a reader most needs to see that
    /// something moved.
    private struct PageKey: Hashable {
        let chapter: Int
        let page: Int
    }

    /// How far a page slides as it comes and goes. Enough to read as a turn,
    /// short enough that the text is never legible in the wrong place.
    private static let slide: CGFloat = 48
    private static let turnDuration = 0.3

    var body: some View {
        // Every model read happens here, on the main actor, and the values are
        // handed to `PageSurface` as plain data. That is what lets the outgoing
        // page keep drawing the *old* sentence while the model has already
        // moved on to the next — and it is the rule the tvOS `ViewThatFits`
        // crash was about: a view SwiftUI may size or draw off the main actor
        // must not read a `@MainActor` model from inside a closure.
        let layout = model.layout
        let page = model.currentPage
        let key = PageKey(chapter: model.chapterIndex, page: model.pageIndex)
        let activeFragment = model.activeFragmentID
        let annotations = page.map { model.highlightBlocks(on: $0) } ?? []
        let selection = model.selection
        let theme = model.style.theme
        // The reader's own highlighter for this page colour, so the television
        // paints the block the same colour the phone and the Mac do.
        let highlight = model.style.highlightColor
        let highlightStyle = HighlightBlock.Style(fontSize: model.style.fontSize)

        ZStack {
            if let layout, let page {
                PageSurface(
                    layout: layout,
                    page: page,
                    activeFragment: activeFragment,
                    annotations: annotations,
                    selection: selection,
                    theme: theme,
                    highlight: highlight,
                    highlightStyle: highlightStyle,
                    size: size,
                )
                .id(key)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: forward ? Self.slide : -Self.slide)),
                        removal: .opacity.combined(with: .offset(x: forward ? -Self.slide : Self.slide)),
                    ),
                )
            } else {
                // The chapter is still laying out. An empty band the exact size
                // of the page means the header, the timeline and the footer do
                // not shuffle when the glyphs arrive.
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(.easeInOut(duration: Self.turnDuration), value: key)
        .focusable()
        .focused($focus, equals: .page)
        .onMoveCommand { direction in
            switch direction {
            case .left: turn(forward: false)
            case .right: turn(forward: true)
            case .down: focus = .transport
            default: break
            }
        }
        .modifier(PageAccessibility(model: model))
    }

    /// Turns the page, once.
    private func turn(forward direction: Bool) {
        guard !turning else { return }
        turning = true
        forward = direction
        Task {
            await model.turnPage(forward: direction)
            turning = false
        }
    }
}
