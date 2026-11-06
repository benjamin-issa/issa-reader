import IssaCore
import IssaUI
import SwiftUI

/// The Library tab's stack and, where the display divides (iPhone Duo's inner
/// display held wide), the selected book's page beside it with the divider on
/// the fold.
///
/// One stack in one place whether the pane is there or not, so opening and
/// closing the phone keeps the shelf, the search and the scroll position: the
/// pane comes and goes beside it. Everywhere else — every iPhone, every iPad,
/// and the Duo closed — it is the stack alone, as 1.5.2 drew it.
struct LibrarySplit<Stack: View>: View {
    @Environment(\.adaptiveSignals) private var signals
    @Environment(AppModel.self) private var app
    let selection: SplitBookSelection
    @Binding var path: NavigationPath
    let stack: Stack

    init(selection: SplitBookSelection, path: Binding<NavigationPath>, @ViewBuilder stack: () -> Stack) {
        self.selection = selection
        _path = path
        self.stack = stack()
    }

    /// Where this view begins in the window, which the fold is measured in.
    @State private var minX: CGFloat = 0
    /// The divider as the split last showed it, kept for as long as `held`.
    @State private var heldDivider: CGFloat?

    /// Whether something stands over the split, so that it stays as it is.
    ///
    /// The page in the pane presents the reader, and the page close pushed
    /// carries whatever has been opened from it. Moving either page between the
    /// pane and the stack destroys it, and everything over it with it: a reader
    /// dismissed by opening the phone, in the middle of a page. So the split
    /// only changes while nothing stands over it, and catches up the moment
    /// that stops being true.
    private var held: Bool {
        app.visibleReaderUUID != nil || selection.holdsSplit(given: path)
    }

    var body: some View {
        let live = signals.divider.map { $0 - minX }
        // Asked only where there is a split to hold, so every other device goes
        // on drawing the stack alone with nothing new to observe.
        let holding = (live != nil || heldDivider != nil) && held
        let divider = holding ? heldDivider : live
        let pane: SplitBookSelection? = divider == nil ? nil : selection
        // Measured rather than wrapped in a geometry reader, so with no pane
        // the stack is laid out exactly as it was without this view.
        HStack(spacing: 0) {
            stack
                .environment(pane)
                .frame(width: divider.map { max($0, 0) })
            if divider != nil {
                Rectangle()
                    .fill(Palette.border)
                    .frame(width: 1)
                    .ignoresSafeArea()
                detail
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minX } action: { minX = $0 }
        .onChange(of: divider, initial: true) { _, shown in
            if !holding { heldDivider = shown }
        }
        .onChange(of: divider != nil, initial: true) { _, split in
            selection.isSplit = split
        }
        .onChange(of: divider != nil) { _, split in
            if split { selection.open(&path) } else { selection.close(&path) }
        }
    }

    private var detail: some View {
        NavigationStack {
            if let book = selection.book {
                BookDetailView(book: book)
                    .id("\(book.uuid)-\(selection.requests)")
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            // The book's own menu, so the page beside the shelf
                            // has what a long press on its cover has. Several
                            // rows, never one: see `ReaderOverflow`.
                            Menu {
                                BookMenuItems(book: book)
                            } label: {
                                Label("More", systemImage: "ellipsis.circle")
                            }
                            .accessibilityIdentifier("split.more")
                        }
                    }
            } else {
                ContentUnavailableView(
                    "Choose a Book", systemImage: "books.vertical",
                    description: Text("Its details open here, beside the shelf."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The shelf's paper, as the book's own page has, not the
                    // system's white.
                    .background(Palette.paper)
            }
        }
        .accessibilityIdentifier("split.detail")
    }
}
