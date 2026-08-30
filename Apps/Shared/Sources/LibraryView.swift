import IssaCore
import IssaUI
import SwiftUI

/// The library grid, with the "Continue" card the design leads with.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var results: [Book] = []

    public init() {}

    /// Search results are already the answer to a question; re-sorting them by
    /// title would bury the best match. Arrangement applies to the shelf only.
    private var books: [Book] {
        search.isEmpty ? app.arrangedBooks : results
    }

    private var heading: String {
        if !search.isEmpty {
            return "\(books.count) result\(books.count == 1 ? "" : "s")"
        }
        let shelf = app.arrangement.shelf.title
        return app.arrangement.isFiltering ? "\(shelf) · \(books.count)" : shelf
    }

    #if !os(tvOS)
    /// One menu for shelf, sort and tags: three separate controls would crowd
    /// a phone header, and these are read together anyway.
    @ViewBuilder
    private var arrangeMenu: some View {
        @Bindable var app = app
        Menu {
            Picker("Shelf", selection: $app.arrangement.shelf) {
                ForEach(LibraryArrangement.Shelf.allCases) { shelf in
                    Text(shelf.title).tag(shelf)
                }
            }
            Picker("Sort by", selection: $app.arrangement.sort) {
                ForEach(LibraryArrangement.Sort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            Toggle("Reverse order", isOn: $app.arrangement.ascending)

            let tags = app.derivation.tagCounts.prefix(12)
            if !tags.isEmpty {
                Menu("Tags") {
                    if !app.arrangement.tags.isEmpty {
                        Button("Clear tags") { app.arrangement.tags = [] }
                        Divider()
                    }
                    ForEach(Array(tags), id: \.name) { tag in
                        Button {
                            if app.arrangement.tags.contains(tag.name) {
                                app.arrangement.tags.remove(tag.name)
                            } else {
                                app.arrangement.tags.insert(tag.name)
                            }
                        } label: {
                            Label(
                                "\(tag.name) (\(tag.count))",
                                systemImage: app.arrangement.tags.contains(tag.name) ? "checkmark" : "",
                            )
                        }
                    }
                }
            }
        } label: {
            Image(systemName: app.arrangement.isFiltering
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
                .font(.system(size: 17))
                .foregroundStyle(Palette.tangerine)
        }
        .accessibilityLabel("Sort and filter")
    }
    #endif

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing32, pinnedViews: []) {
                if search.isEmpty, let current = app.derivation.continueReading.first {
                    // Wrapped the same way BookGridItem is. The card was styled
                    // from the design canvas and never given an affordance, so
                    // the app's most prominent control did nothing at all.
                    ContinueCardLink(book: current, session: app.session)
                }

                VStack(alignment: .leading, spacing: Metrics.spacing12) {
                    HStack {
                        Text(heading).overlineStyle()
                        Spacer()
                        #if !os(tvOS)
                        arrangeMenu
                        #endif
                    }
                    if books.isEmpty, search.isEmpty, app.arrangement.isFiltering {
                        // A filtered library that matches nothing must not read
                        // as an empty library.
                        Text("No books on this shelf.")
                            .font(Typography.footnote)
                            .foregroundStyle(Palette.inkTertiary)
                            .padding(.vertical, Metrics.spacing24)
                    }
                    BookGrid(books: books, session: app.session)
                }
            }
            .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .searchable(text: $search, prompt: "Search your library")
        // Full-text, from the local index: the server's book endpoint takes no
        // query parameters at all, so search has to happen here either way.
        .task(id: search) {
            guard !search.isEmpty else { results = []; return }
            results = await app.search(search)
        }
        .refreshable { await app.refreshLibrary() }
        .overlay {
            if app.books.isEmpty, app.isLoadingLibrary {
                ProgressView()
            } else if app.books.isEmpty, let error = app.loadError {
                // A failed fetch is not an empty library, and showing "no books"
                // for a decode error sends you looking in entirely the wrong place.
                ContentUnavailableView {
                    Label("Couldn't load your library", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await app.refreshLibrary() } }
                }
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
                BookGridItem(book: book, session: session)
                    // Rows size to their tallest cell and centre vertically —
                    // LazyVGrid's alignment is horizontal only — so a title
                    // wrapping to two lines pushed its neighbours down.
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// Opens a book the way each platform expects: a pushed screen on iOS and
/// tvOS, and a separate window on the Mac.
struct BookGridItem: View {
    let book: Book
    let session: Session?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if let session {
            #if os(macOS)
            Button {
                openWindow(id: "Reader", value: book.uuid)
            } label: {
                BookCell(book: book, session: session)
            }
            .buttonStyle(.plain)
            #else
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                BookCell(book: book, session: session)
            }
            .buttonStyle(.plain)
            #endif
        } else {
            BookCell(book: book, session: session)
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
            // Two lines' worth of room whether the title needs it or not, so a
            // one-line title does not pull its byline up above the neighbours'.
            Text(book.title)
                .font(Typography.subhead)
                .foregroundStyle(Palette.ink)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
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
/// Makes the Continue card open its book.
///
/// Mirrors `BookGridItem` rather than inventing a second pattern: a pushed
/// screen on iOS and tvOS, a window on the Mac. A value-based NavigationLink
/// would have been shorter but only iOS registers a Book destination, so it
/// would silently do nothing on the other two platforms.
struct ContinueCardLink: View {
    let book: Book
    let session: Session?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if let session {
            #if os(macOS)
            Button {
                openWindow(id: "Reader", value: book.uuid)
            } label: {
                ContinueCard(book: book, session: session)
            }
            .buttonStyle(.plain)
            #else
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                ContinueCard(book: book, session: session)
            }
            .buttonStyle(.plain)
            #endif
        } else {
            ContinueCard(book: book, session: session)
        }
    }
}

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
