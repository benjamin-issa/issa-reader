import IssaCore
import IssaUI
import SwiftUI

/// A series in reading order.
///
/// Looked up by name on every body, the way `BookDetailView` re-resolves its
/// book: the group is derived from the catalogue, and a value handed over at
/// navigation time would stop reflecting a status or position change. A group
/// that has gone — its books removed, or down to one — says so rather than
/// showing a stale list.
struct SeriesView: View {
    @Environment(AppModel.self) private var app
    let name: String

    private var series: SeriesGroup? {
        app.rails.series.first { $0.name == name }
    }

    var body: some View {
        ScrollView {
            if let series {
                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text("\(series.books.count) books").overlineStyle()
                    BookGrid(books: series.books, session: app.session) { book in
                        series.position(of: book).map(BookDetailView.positionText)
                    }
                }
                .padding(Metrics.spacing16)
            }
        }
        .background(Palette.paper)
        .navigationTitle(name)
        .overlay {
            if series == nil {
                PalettePlaceholder(
                    symbol: "books.vertical",
                    title: "Series unavailable",
                    message: "These books are no longer in your library.",
                )
            }
        }
    }
}

/// Every series, as tiles.
struct SeriesListView: View {
    @Environment(AppModel.self) private var app

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: Metrics.spacing16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.spacing24) {
                ForEach(app.rails.series) { group in
                    SeriesTile(series: group)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .navigationTitle("Series")
    }
}
