import IssaCore
import IssaUI
import SwiftUI

/// The library grid, with the "Continue" card the design leads with.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""

    public init() {}

    private var books: [Book] {
        app.derivation.search(search)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing32, pinnedViews: []) {
                if search.isEmpty, let current = app.derivation.continueReading.first {
                    ContinueCard(book: current, session: app.session)
                }

                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    Text(search.isEmpty ? "All books" : "\(books.count) result\(books.count == 1 ? "" : "s")")
                        .overlineStyle()
                    BookGrid(books: books, session: app.session)
                }
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .searchable(text: $search, prompt: "Search your library")
        .refreshable { await app.refreshLibrary() }
        .overlay {
            if app.books.isEmpty, app.isLoadingLibrary {
                ProgressView()
            } else if app.books.isEmpty {
                ContentUnavailableView(
                    "No books yet",
                    systemImage: "books.vertical",
                    description: Text("Add books to your Storyteller server and they'll appear here."),
                )
            }
        }
    }
}

/// Adaptive cover grid. Stable identity plus a fixed aspect keeps scrolling
/// smooth — SwiftUI can size every cell without measuring its content.
public struct BookGrid: View {
    let books: [Book]
    let session: Session?

    public init(books: [Book], session: Session?) {
        self.books = books
        self.session = session
    }

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: Metrics.spacing16)]

    public var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.spacing24) {
            ForEach(books) { book in
                if let session {
                    NavigationLink {
                        ReaderView(book: book, session: session)
                    } label: {
                        BookCell(book: book, session: session)
                    }
                    .buttonStyle(.plain)
                } else {
                    BookCell(book: book, session: session)
                }
            }
        }
    }
}

public struct BookCell: View {
    let book: Book
    let session: Session?

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ZStack(alignment: .bottomLeading) {
                CoverImage(book: book, session: session)
                if let progress = book.progress, progress > 0 {
                    ProgressBar(value: progress)
                        .padding(Metrics.spacing4)
                }
            }
            Text(book.title)
                .font(Typography.subhead)
                .foregroundStyle(Palette.ink)
                .lineLimit(2)
            Text(book.byline)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
        }
    }
}

public struct ProgressBar: View {
    let value: Double

    public init(value: Double) { self.value = value }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.25))
                Capsule().fill(Palette.tangerine)
                    .frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 3)
    }
}

/// The design's lead card: current book, chapter, time left.
public struct ContinueCard: View {
    let book: Book
    let session: Session?

    public var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing16) {
            CoverImage(book: book, session: session)
                .frame(width: 92)

            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Continue").overlineStyle(Palette.tangerine)
                Text(book.title)
                    .font(Typography.title)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(book.byline)
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkTertiary)
                if let progress = book.progress {
                    ProgressBar(value: progress).frame(maxWidth: 220)
                    Text("\(Int(progress * 100))% complete")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.inkSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Metrics.spacing16)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                .strokeBorder(Palette.border, lineWidth: 1),
        )
    }
}
