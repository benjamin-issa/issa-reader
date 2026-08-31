import IssaCore
import IssaUI
import SwiftUI

/// The library grid, with the "Continue" card the design leads with.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var results: [Book] = []

    public init() {}

    @ViewBuilder
    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing32, pinnedViews: []) {
                if search.isEmpty, let current = app.continueBook {
                    // Wrapped the same way BookGridItem is. The card was styled
                    // from the design canvas and never given an affordance, so
                    // the app's most prominent control did nothing at all.
                    ContinueCardLink(book: current, session: app.session)
                }

                if books.isEmpty, search.isEmpty, app.arrangement.isFiltering {
                    // A shelf is one tap away now rather than three levels into
                    // a menu, so readers land here far more often than they did.
                    EmptyShelfView(shelf: app.arrangement.shelf.title) {
                        app.arrangement.shelf = .all
                        app.arrangement.tags = []
                    }
                } else {
                    BookGrid(books: books, session: app.session)
                }
            }
            .padding(Metrics.spacing16)
        }
        .refreshable { await app.refreshLibrary() }
    }

    /// Search results are already the answer to a question; re-sorting them by
    /// title would bury the best match. Arrangement applies to the shelf only.
    private var books: [Book] {
        search.isEmpty ? app.arrangedBooks : results
    }

    public var body: some View {
        // The header is a sibling of the scroll view, not its first item: a
        // child would scroll away, and the refresh control's inset lives at the
        // top of the scroll content, where a changing height once inflated it
        // permanently.
        VStack(spacing: 0) {
            LibraryHeader(
                search: $search, displayedCount: books.count, isSearching: !search.isEmpty)
            scrollContent
        }
        .background(Palette.paper)
        #if !os(iOS)
        // The Mac keeps its toolbar search — the sidebar is already its shelf
        // control — and tvOS renders TVLibraryView, so this only has to compile.
        .searchable(text: $search, prompt: "Search your library")
        #endif
        // Full-text, from the local index: the server's book endpoint takes no
        // query parameters at all, so search has to happen here either way.
        .task(id: search) {
            guard !search.isEmpty else { results = []; return }
            results = await app.search(search)
        }
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

    /// Which cover to ask for. The Listening screen is all audio, so it wants
    /// the square audiobook art the players use.
    let shape: LibraryService.CoverShape

    /// Off where every book already has audio, so the mark says nothing.
    let showsFormatMark: Bool

    public init(
        books: [Book], session: Session?,
        shape: LibraryService.CoverShape = .portrait,
        showsFormatMark: Bool = true,
    ) {
        self.books = books
        self.session = session
        self.shape = shape
        self.showsFormatMark = showsFormatMark
    }

    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: Metrics.spacing16)]

    public var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.spacing24) {
            ForEach(books) { book in
                BookGridItem(
                    book: book, session: session, shape: shape,
                    showsFormatMark: showsFormatMark)
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
    var shape: LibraryService.CoverShape = .portrait
    var showsFormatMark = true
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if let session {
            #if os(macOS)
            Button {
                openWindow(id: "Reader", value: book.uuid)
            } label: {
                BookCell(book: book, session: session, shape: shape, showsFormatMark: showsFormatMark)
            }
            .buttonStyle(.plain)
            #else
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                BookCell(book: book, session: session, shape: shape, showsFormatMark: showsFormatMark)
            }
            .buttonStyle(.plain)
            #endif
        } else {
            BookCell(book: book, session: session, shape: shape, showsFormatMark: showsFormatMark)
        }
    }
}

public struct BookCell: View {
    let book: Book
    let session: Session?
    var shape: LibraryService.CoverShape = .portrait
    /// Off on a screen made entirely of audiobooks, where marking every cover
    /// marks nothing.
    var showsFormatMark = true

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            ZStack(alignment: .bottomLeading) {
                CoverImage(
                    book: book, session: session,
                    aspect: shape == .square ? 1 : Metrics.coverAspect, shape: shape)
                    // An overlay, not another ZStack child: this stack is
                    // bottom-leading for the progress bar, and CoverImage is
                    // built on `Color.clear.aspectRatio` precisely so overlay
                    // content is sized to it and can never grow it.
                    .overlay(alignment: .topTrailing) {
                        if showsFormatMark { formatMark }
                    }
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

    /// Whether a book can be listened to, in one glyph.
    ///
    /// One mark rather than a dot per format: most of a library is an ebook, so
    /// marking that marks nothing, and a legend under a scrolling grid is a
    /// lookup table that is off screen exactly when it is wanted. A shape also
    /// survives being colour-blind, which three coloured dots do not.
    ///
    /// Reads `servableFormats`, so it never promises narration the server has a
    /// row for but no file behind.
    @ViewBuilder
    private var formatMark: some View {
        let formats = book.servableFormats
        if formats.contains(.readaloud) || formats.contains(.audiobook) {
            Image(systemName: formats.contains(.readaloud) ? "waveform" : "headphones")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(4)
                // Its own ground, because a cover is arbitrary artwork and a
                // bare glyph on a dark one is invisible.
                .background(Palette.surface.opacity(0.92), in: Circle())
                .padding(Metrics.spacing4)
                .accessibilityLabel(formats.contains(.readaloud) ? "Read along" : "Audiobook")
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
                    Text("\(ReadingProgress.percent(progress))% complete")
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
