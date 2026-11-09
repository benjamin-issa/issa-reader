import IssaCore
import IssaUI
import SwiftUI

// The SwiftUI side of `AdaptiveLayout` (1.6.0, iPhone Duo). Everything that
// decides lives in IssaUI and IssaRender, where it is tested; this file only
// reads what the system says and publishes it.

extension EnvironmentValues {
    /// What the system says about this window: its size classes, the edge it
    /// runs its bars down and its reserved regions, in window coordinates.
    ///
    /// Read once, where the size classes are still the window's own (a split
    /// pane overrides them), by `readsAdaptiveSignals()`. `.none` on the Mac,
    /// the television, and every iPhone and iPad before iOS 27.1, which is the
    /// layout 1.5.2 drew.
    @Entry var adaptiveSignals: AdaptiveLayout.Signals = .none
}

extension View {
    /// Publishes `\.adaptiveSignals` below this view, which must be the size of
    /// the window: the regions are read in its coordinates.
    @ViewBuilder
    func readsAdaptiveSignals() -> some View {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            modifier(AdaptiveSignalsReader())
        } else {
            self
        }
        #else
        self
        #endif
    }
}

extension View {
    /// A Close button in a sheet's bar where the system runs its bars down a
    /// side (iPhone Duo). A sheet there stands to one side of the fold with a
    /// vertical bar of its own, and its one control is the way out; a swipe
    /// down a sheet beside a fold is not one anybody would find. Nothing
    /// anywhere else, where the sheet is swiped away as it always was.
    ///
    /// On the sheet's root view, inside its navigation stack.
    func closesWhenBarsRunDownTheSide() -> some View {
        modifier(SideBarClose())
    }
}

private struct SideBarClose: ViewModifier {
    @Environment(\.adaptiveSignals) private var signals
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        #if os(iOS)
        content.toolbar {
            if signals.bars != .top {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .accessibilityIdentifier("sheet.close")
                }
            }
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// Which book stands beside the Library on iPhone Duo's inner display.
///
/// In the environment while the split is showing, and absent otherwise, so a
/// cover asks one question — is there a pane to select into? — and pushes the
/// book's page as it always has when there is not (`BookLink`). The Mac's
/// inspector is the same idea (`MacBookSelection`).
@MainActor
@Observable
final class SplitBookSelection {
    var book: Book?
    /// Whether the pane is showing, and so where a book asked for goes.
    var isSplit = false
    /// Counts the books asked for, so that asking for the one already in the
    /// pane builds its page again and a request to read it is taken up.
    private(set) var requests = 0
    /// The book a close pushed onto the stack, and the stack it left: what
    /// `open` needs to know that page is still the one showing.
    private var collapsed: (book: Book, path: NavigationPath)?
    /// Whether another page has been pushed over that one. Most screens are
    /// pushed by `NavigationLink(destination:)` and never appear in a path, so
    /// the page has to say so itself.
    private var pageIsCovered = false
    /// Whether a page stands over the shelf, which the shelf has to say for the
    /// same reason.
    private var shelfIsCovered = false

    /// Closed: the selected book's page becomes the one the stack shows, so
    /// the outer display carries on where the inner one was, and Back goes to
    /// the shelf.
    ///
    /// Not over a page the path cannot see. Changing the path takes such a page
    /// off the stack, and Back from the book then skipped it. The book stays
    /// chosen instead, and is in the pane when the phone opens.
    func close(_ path: inout NavigationPath) {
        guard let book, !shelfIsCovered else { return }
        path.append(book)
        collapsed = (book, path)
        pageIsCovered = false
        self.book = nil
    }

    /// Opened again: the page that close pushed goes back into the pane, if
    /// the stack is as close left it. Back from that page empties it, and a
    /// link replaces it, and then there is nothing of close's left to move.
    /// Compared whole, because a link can replace it at the same depth.
    func open(_ path: inout NavigationPath) {
        guard let collapsed else { return }
        self.collapsed = nil
        guard path == collapsed.path else { return }
        path.removeLast()
        book = collapsed.book
    }

    /// Whether a page stands over the one close pushed, so that the split has
    /// to wait for the reader to come back to it. Taking that page from under
    /// them would take theirs with it. Not once Back has left it, or a link has
    /// replaced it: then it is not on the stack to be covered.
    func holdsSplit(given path: NavigationPath) -> Bool {
        pageIsCovered && collapsed?.path == path
    }

    /// The shelf came into view, or was uncovered.
    func shelfAppeared() {
        shelfIsCovered = false
    }

    /// The shelf left view: a page has been pushed over it.
    func shelfDisappeared() {
        shelfIsCovered = true
    }

    /// The page for this book came into view, or was uncovered.
    func pageAppeared(_ book: Book) {
        if collapsed?.book.uuid == book.uuid { pageIsCovered = false }
    }

    /// The page for this book left view, and if it is still the stack's, a
    /// page has been pushed over it.
    func pageDisappeared(_ book: Book) {
        if collapsed?.book.uuid == book.uuid { pageIsCovered = true }
    }

    /// A book asked for from outside: a link, a widget, Handoff. In the pane
    /// where there is one. Otherwise on the stack, as the page close would have
    /// pushed, so that opening the phone puts it beside the shelf rather than
    /// leaving it in the shelf's half of the display.
    func show(_ book: Book, in path: inout NavigationPath) {
        path = NavigationPath()
        requests &+= 1
        if isSplit {
            collapsed = nil
            self.book = book
        } else {
            self.book = nil
            path.append(book)
            collapsed = (book, path)
            pageIsCovered = false
        }
    }
}

@available(iOS 27.1, *)
private struct AdaptiveSignalsReader: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontal
    @Environment(\.verticalSizeClass) private var vertical
    @Environment(\.toolbarVerticalEdge) private var barEdge
    @State private var regions = Regions()

    struct Regions: Equatable {
        var folds: [AdaptiveLayout.Region] = []
        var occlusions: [AdaptiveLayout.Region] = []
        var window: CGSize = .zero
    }

    func body(content: Content) -> some View {
        content
            .environment(\.adaptiveSignals, AdaptiveLayout.Signals(
                horizontal: Self.sizeClass(horizontal), vertical: Self.sizeClass(vertical),
                bars: Self.bars(barEdge), folds: regions.folds, occlusions: regions.occlusions,
                window: regions.window,
            ))
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: Self.regions(proxy), initial: true) { _, read in regions = read }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }

    private static func regions(_ proxy: GeometryProxy) -> Regions {
        func read(_ kind: ReservedRegion.Kind) -> [AdaptiveLayout.Region] {
            proxy.reservedRegions(kind: kind, options: [.includeInactive])
                .map { AdaptiveLayout.Region(frame: $0.frame, isActive: $0.isActive) }
        }
        return Regions(folds: read(.division), occlusions: read(.occlusion), window: proxy.size)
    }

    private static func sizeClass(_ sizeClass: UserInterfaceSizeClass?) -> AdaptiveLayout.SizeClass? {
        switch sizeClass {
        case .compact: .compact
        case .regular: .regular
        default: nil
        }
    }

    private static func bars(_ edge: HorizontalEdge?) -> AdaptiveLayout.BarEdge {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        default: .top
        }
    }
}
#endif
