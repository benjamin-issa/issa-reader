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
    /// The book a close pushed onto the stack, and the stack it left: what
    /// `open` needs to know that page is still the one showing.
    private var collapsed: (book: Book, path: NavigationPath)?

    /// Closed: the selected book's page becomes the one the stack shows, so
    /// the outer display carries on where the inner one was, and Back goes to
    /// the shelf.
    func close(_ path: inout NavigationPath) {
        guard let book else { return }
        path.append(book)
        collapsed = (book, path)
        self.book = nil
    }

    /// Opened again: the page that close pushed goes back into the pane, if
    /// the stack is as close left it. On the outer display the reader may have
    /// gone Back from that page, or followed a link to another book, and
    /// taking the last page then would remove the one they are on and bring
    /// back the one they left. Compared whole, because a link can replace the
    /// page with another at the same depth.
    func open(_ path: inout NavigationPath) {
        guard let collapsed else { return }
        self.collapsed = nil
        guard path == collapsed.path else { return }
        path.removeLast()
        book = collapsed.book
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
