import IssaRender
import IssaUI
import SwiftUI

/// One page of the book on a television, and the remote that turns it.
///
/// The page is drawn by `PageTrackView` — the same view the phone and the Mac
/// use, so the read-along block, the stored highlights, the glyphs and the way
/// a page slides are identical here — and everything this view adds is about
/// the remote: which direction turns a page and where focus goes.
struct TVPageView: View {
    let model: ReaderModel
    let size: CGSize
    @FocusState.Binding var focus: TVFocus?

    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Slides, covers or simply changes the page, as the reader chose.
    ///
    /// It used to be a 48-point slide and fade keyed on the page itself, so
    /// every change of page animated — narration moving on included. Now only
    /// a press of the remote does, and the narration's own turns are instant,
    /// as they are on the phone and in Storyteller's readers. And a held-down
    /// remote, which repeats, turns as many pages as it repeats: a press
    /// mid-slide finishes the slide and makes its own turn, where it used to be
    /// dropped.
    @State private var turner: PageTurner

    init(model: ReaderModel, size: CGSize, focus: FocusState<TVFocus?>.Binding) {
        self.model = model
        self.size = size
        _focus = focus
        _turner = State(initialValue: PageTurner(model: model))
    }

    var body: some View {
        PageTrackView(
            model: model,
            turner: turner,
            pageSize: size,
            insets: EdgeInsets(),
        )
        .frame(width: size.width, height: size.height)
        .onChange(of: size.width, initial: true) { _, width in turner.width = width }
        .onChange(of: model.pageKey) { _, key in turner.modelKeyChanged(key) }
        .onChange(of: PageTurn.effectiveStyle(settings.pageTurn, reduceMotion: reduceMotion), initial: true) {
            _, style in turner.style = style
        }
        .focusable()
        .focused($focus, equals: .page)
        .onMoveCommand { direction in
            switch direction {
            case .left: turn(forward: false)
            case .right: turn(forward: true)
            default:
                // Through `TVFocusMoves`, never `focus = .transport` outright.
                // Down used to move focus off the page whether or not there was
                // a transport row to move it to, and on a plain ebook there was
                // not: `onMoveCommand` is attached to the page, so once focus
                // left it Left and Right stopped turning pages and Menu — which
                // leaves the book — was the only way out.
                if let next = TVFocusMoves.destination(
                    for: direction, from: .page, hasNarration: model.hasNarration,
                ) {
                    focus = next
                }
            }
        }
        // Outermost, around the focusable page, where it has always been.
        .modifier(PageAccessibility(model: model) { forward in turn(forward: forward, announcing: true) })
    }

    /// Turns the page, taking the voice with it: on the television the page is
    /// the scrubber, so a turn that left the voice behind would be snapped
    /// straight back at the next sentence.
    private func turn(forward: Bool, announcing: Bool = false) {
        turner.requestTurn(forward: forward, carriesNarration: true) {
            if announcing { PageAccessibility.announcePage(model) }
        }
    }
}
