import IssaCore
import IssaUI
import SwiftUI

/// The library grid.
///
/// The Continue card used to lead here; it lives on the Reading tab now — one
/// home per job — and `ContinueCardLink` below is what that tab draws.
public struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var search = ""
    @State private var results: [Book] = []

    public init() {}

    @ViewBuilder
    private var scrollContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.spacing32, pinnedViews: []) {
                #if os(iOS)
                if app.libraryMode == .browse, search.isEmpty {
                    // Search results are an answer, and they are shown
                    // whichever mode is on; only an idle Browse gets rails.
                    BrowseView()
                } else {
                    shelf
                }
                #elseif os(macOS)
                // Rails only on All books. The sidebar is the Mac's shelf
                // control, so picking a shelf there means "show me that cut of
                // the library", which is the grid. Rails are what the wide
                // window is for when no cut has been asked for.
                if app.libraryMode == .browse, search.isEmpty, app.arrangement.shelf == .all {
                    BrowseView()
                } else {
                    shelf
                }
                #else
                // tvOS renders TVLibraryView; this only has to compile.
                shelf
                #endif
            }
            .padding(Metrics.screenMargin)
        }
        .refreshable { await app.refreshLibrary() }
    }

    /// The flat grid, or what an empty shelf says.
    @ViewBuilder
    private var shelf: some View {
        if books.isEmpty, search.isEmpty, app.arrangement.isFiltering {
            // A shelf is one tap away now rather than three levels into
            // a menu, so readers land here far more often than they did.
            EmptyShelfView(shelf: app.arrangement.shelf.title) {
                app.showAllBooks(shelf: .all)
            }
        } else {
            BookGrid(books: books, session: app.session)
        }
    }

    #if os(macOS)
    /// The toolbar switch.
    ///
    /// Reads as "All Books" whenever rails are not what is on screen, so the
    /// segment never claims Browse over a grid. Setting `.all` writes the mode
    /// and nothing else — the grid keeps the sort and tags it already had,
    /// which is what "with all its controls intact" has to mean.
    private var modeBinding: Binding<AppModel.LibraryMode> {
        Binding(
            get: {
                guard app.arrangement.shelf == .all, search.isEmpty else { return .all }
                return app.libraryMode
            },
            set: { app.libraryMode = $0 },
        )
    }
    #endif

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
        // Under the safe area, which the Reading tab and Settings already do by
        // painting a scroll view. Here the paper was on a stack laid out inside
        // it, so the strip behind the tab bar's glass accessory was the host's
        // own white — the one place in the app where that showed.
        .background(Palette.paper.ignoresSafeArea())
        #if !os(iOS)
        // The Mac keeps its toolbar search — the sidebar is already its shelf
        // control — and tvOS renders TVLibraryView, so this only has to compile.
        .searchable(text: $search, prompt: "Search your library")
        #endif
        #if os(macOS)
        // Browse or the sortable grid, in the window's own toolbar. Disabled
        // where rails would be a lie: on a named shelf, and while a search is
        // showing results.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Library view", selection: modeBinding) {
                    Text("Browse").tag(AppModel.LibraryMode.browse)
                    Text("All Books").tag(AppModel.LibraryMode.all)
                }
                .pickerStyle(.segmented)
                .disabled(app.arrangement.shelf != .all || !search.isEmpty)
                .accessibilityLabel("Library view")
            }
        }
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
                PalettePlaceholder(
                    symbol: "exclamationmark.triangle",
                    title: "Couldn't load your library",
                    message: error,
                    actionTitle: "Try again",
                    action: { Task { await app.refreshLibrary() } },
                )
            } else if app.books.isEmpty {
                PalettePlaceholder(
                    symbol: "books.vertical",
                    title: "No books yet",
                    message: "Add books to your Storyteller server and they'll appear here.",
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

    /// A line under the title in place of the byline — a series screen says
    /// "Book 2" where the author's name would say nothing new.
    let caption: ((Book) -> String?)?

    public init(
        books: [Book], session: Session?,
        shape: LibraryService.CoverShape = .portrait,
        showsFormatMark: Bool = true,
        caption: ((Book) -> String?)? = nil,
    ) {
        self.books = books
        self.session = session
        self.shape = shape
        self.showsFormatMark = showsFormatMark
        self.caption = caption
    }

    // A cover sized for a hand is a postage stamp across a room, so the
    // television asks for roughly three times the width. Spacing follows the
    // scaled metric on its own.
    #if os(tvOS)
    private let columns = [GridItem(.adaptive(minimum: 300, maximum: 340), spacing: Metrics.spacing16)]
    #else
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 160), spacing: Metrics.spacing16)]
    #endif

    public var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.spacing24) {
            ForEach(books) { book in
                BookGridItem(
                    book: book, session: session, shape: shape,
                    showsFormatMark: showsFormatMark, caption: caption?(book))
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
    var caption: String?

    var body: some View {
        #if os(tvOS)
        TVPosterItem(
            book: book, session: session, shape: shape,
            showsFormatMark: showsFormatMark, caption: caption)
        #else
        BookLink(book: book, session: session) {
            BookCell(
                book: book, session: session, shape: shape,
                showsFormatMark: showsFormatMark, caption: caption)
        }
        #endif
    }
}

#if os(tvOS)
/// A poster on a television: the cover lifts on focus, the words sit still
/// beneath it.
///
/// The words are deliberately *outside* the focusable button, which is the fix
/// for two faults at once. tvOS's focus treatment clips a button's label to the
/// label's own bounds, so a title inside it loses its leading characters as the
/// card grows — "he Hero of Ages". And the hand-rolled `scaleEffect` that used
/// to sit on top of that reserved no layout space, so the grown cell was clipped
/// a second time by the enclosing scroll view. The platform's own card lift does
/// the job and reserves the room for it.
///
/// The fixed width is the other half. A single-line `Text` lays out at its full
/// ideal width when nothing bounds it — and a horizontal `ScrollView` proposes
/// exactly that — so "This Is How You Lose the Time War" ran far past its cover
/// and dragged the poster out of registration with its neighbours. Bounding the
/// whole cell means the title can never be wider than the artwork above it.
struct TVPosterItem: View {
    let book: Book
    let session: Session?
    var shape: LibraryService.CoverShape = .portrait
    var showsFormatMark = true
    var caption: String?

    @FocusState private var focused: Bool

    /// Matches `BookGrid`'s adaptive minimum, so a rail and the grid below it
    /// draw the same poster.
    static let coverWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            if session != nil {
                NavigationLink(value: book) {
                    cell.coverBlock
                }
                // The platform's poster treatment: lift, specular sheen, and
                // layout space reserved for both.
                .buttonStyle(.card)
                .focused($focused)
            } else {
                cell.coverBlock
            }
            cell.captionBlock
                // Dimmed until focused, which is how a ten-foot shelf says
                // which poster the remote is on without shouting.
                .opacity(focused ? 1 : 0.7)
                .animation(.easeOut(duration: 0.15), value: focused)
        }
        .frame(width: Self.coverWidth, alignment: .leading)
    }

    private var cell: BookCell {
        BookCell(
            book: book, session: session, shape: shape,
            showsFormatMark: showsFormatMark, caption: caption)
    }
}
#endif

public struct BookCell: View {
    let book: Book
    let session: Session?
    var shape: LibraryService.CoverShape = .portrait
    /// Off on a screen made entirely of audiobooks, where marking every cover
    /// marks nothing.
    var showsFormatMark = true
    /// Shown instead of the byline when given.
    var caption: String?
    #if os(macOS)
    @Environment(MacBookSelection.self) private var selection: MacBookSelection?
    #endif

    public var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            coverBlock
            captionBlock
        }
        // The ring is a colour; the trait is what VoiceOver has.
        #if os(macOS)
        .accessibilityAddTraits(selection?.bookID == book.uuid ? .isSelected : [])
        #endif
    }

    /// The artwork and everything drawn on it.
    ///
    /// Separated from the words beneath so tvOS can put this — and only this —
    /// inside the focusable button. tvOS's focus treatment clips a button's
    /// label to its own bounds and lifts it with a transform that reserves no
    /// layout space, so a title inside the button loses its first characters as
    /// the card grows. See `TVPosterItem`.
    @ViewBuilder
    var coverBlock: some View {
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
                    // The Mac's selection ring: a click selects into the
                    // inspector rather than opening a window, so the cover has
                    // to say which book the column is describing.
                    #if os(macOS)
                    .overlay {
                        if selection?.bookID == book.uuid {
                            RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                                .strokeBorder(Palette.tangerine, lineWidth: 3)
                        }
                    }
                    #endif
                if let progress = book.progress, progress > 0 {
                    ProgressBar(value: progress)
                        .padding(Metrics.spacing4)
                }
            }
    }

    @ViewBuilder
    var captionBlock: some View {
            // Two lines' worth of room whether the title needs it or not, so a
            // one-line title does not pull its byline up above the neighbours'.
            Text(book.title)
                .font(Typography.subhead)
                .foregroundStyle(Palette.ink)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
            // Truncating, explicitly. A single-line `Text` lays out at its
            // full ideal width when the proposal is unbounded — which is
            // exactly what a horizontal `ScrollView` proposes — so without a
            // width to work against, a long byline runs past its cover instead
            // of ending in an ellipsis. The width itself comes from the caller;
            // see `TVPosterItem`.
            Text(self.caption ?? book.byline)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
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
                .font(.system(size: FormatMarkSize.glyph, weight: .semibold))
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

/// The corner glyph on a cover, which is the one mark small enough that the
/// television needs it stated rather than scaled with the type.
enum FormatMarkSize {
    #if os(tvOS)
    static let glyph: CGFloat = 20
    #else
    static let glyph: CGFloat = 10
    #endif
}

public struct ProgressBar: View {
    let value: Double

    public init(value: Double) { self.value = value }

    /// A three-point bar is a hairline on a television.
    #if os(tvOS)
    private static let thickness: CGFloat = 6
    #else
    private static let thickness: CGFloat = 3
    #endif

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.ink.opacity(0.25))
                Capsule().fill(Palette.tangerine)
                    .frame(width: max(2, geo.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: Self.thickness)
    }
}

/// The Reading tab's lead card: the book you were last in, one tap from its page.
///
/// Two targets, not one. The card body resumes reading the way the widget and
/// Handoff already do — `requestBook(.read)` leaves the book in the pending
/// inbox and `LibraryTabs.openPendingBook` presents the reader at the saved
/// position — while a trailing chevron still routes to the detail screen the
/// whole card used to open. Splitting them is the point of the change: the
/// app's most prominent control now opens a book to read rather than describing
/// one. VoiceOver reads the two as separate elements.
///
/// The Mac keeps opening its own Reader window, which is already resume-first,
/// and its grid has no detail route to add a chevron for; the signed-out
/// placeholder stays inert. tvOS renders `TVLibraryView`, whose poster Continue
/// already pushes straight into the reader, so this card is an iOS concern.
struct ContinueCardLink: View {
    @Environment(AppModel.self) private var app
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
            ContinueCard(book: book, session: session) {
                // The same resume path a widget tap takes; the reader fetches
                // on open when the file is absent (item 02).
                app.requestBook(book.uuid, .read)
            }
            #endif
        } else {
            ContinueCard(book: book, session: session)
        }
    }
}

/// The lead card. Interactive when handed a `resume` action: the body resumes
/// reading and a trailing chevron opens the book's detail screen — two tap
/// targets VoiceOver announces separately. Without one it is a plain visual, so
/// the Mac and signed-out paths can wrap it in their own control.
public struct ContinueCard: View {
    let book: Book
    let session: Session?
    let resume: (() -> Void)?

    public init(book: Book, session: Session?, resume: (() -> Void)? = nil) {
        self.book = book
        self.session = session
        self.resume = resume
    }

    public var body: some View {
        if let resume {
            HStack(spacing: 0) {
                Button(action: resume) { content }
                    .buttonStyle(.plain)
                    // The action, not the contents: read as one flat string,
                    // "Continue / Title / 45% complete" said nothing about what
                    // a tap does. The chevron gets its own label so the two
                    // targets never blur into a single announcement.
                    .accessibilityLabel("Resume \(book.title)")
                    // Honest about where the tap lands: an audiobook-only book
                    // has no reader to resume, so the request opens its screen.
                    .accessibilityHint(book.isReadable
                        ? "Opens the reader where you left off"
                        : "Opens the book")
                detailsLink
            }
            .cardChrome()
        } else {
            content.cardChrome()
        }
    }

    /// Cover, title, byline and progress — the card's visible matter, with a
    /// trailing spacer so the text stays left whether or not a chevron follows.
    private var content: some View {
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
        // So the gap between the text and the chevron still resumes reading.
        .contentShape(Rectangle())
    }

    /// The detail route the whole card used to be. A full-height 44pt column so
    /// it is its own target beside the resume body, never a sliver of it.
    private var detailsLink: some View {
        NavigationLink {
            BookDetailView(book: book)
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.inkTertiary)
                .frame(width: 44)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Details for \(book.title)")
        .accessibilityHint("Opens the book's detail page")
    }
}

private extension View {
    /// The surface, inset and border every Continue card wears, kept in one
    /// place so the interactive and plain layouts cannot drift apart.
    func cardChrome() -> some View {
        padding(Metrics.spacing16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radiusLarge))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusLarge)
                    .strokeBorder(Palette.border, lineWidth: 1),
            )
    }
}
