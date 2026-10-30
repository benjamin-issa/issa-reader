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

    var body: some View {
        let divider = signals.divider.map { $0 - minX }
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
        .onChange(of: divider != nil) { _, split in
            if split { opened() } else { closed() }
        }
    }

    private var detail: some View {
        NavigationStack {
            if let book = selection.book {
                BookDetailView(book: book)
                    .id(book.uuid)
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

    /// Closed: the selected book's page becomes the one the stack shows, so
    /// the outer display carries on where the inner one was, and Back goes to
    /// the shelf.
    private func closed() {
        guard let book = selection.book else { return }
        path.append(book)
        selection.collapsed = book
        selection.book = nil
    }

    /// Opened again: the page that close pushed goes back into the pane.
    private func opened() {
        guard let book = selection.collapsed else { return }
        selection.collapsed = nil
        if !path.isEmpty { path.removeLast() }
        selection.book = book
    }
}
