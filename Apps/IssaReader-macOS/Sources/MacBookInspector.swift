import IssaCore
import IssaUI
import SwiftUI

/// The Mac's book detail, as a third column.
///
/// The Mac has never had a book screen: a cover opened a reader window and
/// everything the phone shows about a book — its rating, its shelf, its
/// series, its editions — was unreachable. This is that screen, in the column
/// beside the grid rather than as a modal, so choosing a book and reading about
/// it do not interrupt each other.
///
/// Its own navigation stack, because the detail's Series row pushes; without
/// one that row would be a link to nowhere.
struct MacBookInspector: View {
    @Environment(AppModel.self) private var app
    let bookID: String?

    var body: some View {
        NavigationStack {
            if let bookID, let book = app.books.first(where: { $0.uuid == bookID }) {
                BookDetailView(book: book, layout: .inspector)
            } else {
                VStack(spacing: Metrics.spacing12) {
                    Image(systemName: "book.closed")
                        .font(.system(size: 32))
                        .foregroundStyle(Palette.inkQuaternary)
                    Text("No book selected")
                        .font(Typography.title)
                        .foregroundStyle(Palette.ink)
                    Text("Click a cover to see its details.")
                        .font(Typography.footnote)
                        .foregroundStyle(Palette.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Metrics.spacing32)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.paper)
            }
        }
    }
}
