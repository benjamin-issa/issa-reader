import IssaCore
import IssaUI
import SwiftUI

#if os(macOS)
/// Which book the Mac's inspector is showing.
///
/// An observable in the environment rather than state threaded through every
/// caller: the cells that draw covers are shared with two other platforms, and
/// they should not have to know the Mac has an inspector beyond asking whether
/// one is present.
@MainActor
@Observable
public final class MacBookSelection {
    public var bookID: String? {
        didSet { if let bookID { lastShownBookID = bookID } }
    }

    /// The last book the inspector showed, so closing it is undoable.
    ///
    /// Without this the "Book Info" toggle was one-way: its setter ignored
    /// `true`, and clearing the id immediately satisfied the `.disabled`
    /// condition, so the control greyed out the moment it was switched off and
    /// the only way back was clicking a cover again.
    public private(set) var lastShownBookID: String?

    /// The page the window's content column should push.
    ///
    /// The inspector has no navigation stack of its own. It used to: on
    /// macOS 27 a stack inside the inspector column re-vends the window's
    /// toolbar on every layout pass, AppKit counts the passes, and the app
    /// dies with "more Update Constraints in Window passes than there are
    /// views in the window" the second time a cover is clicked. So a series
    /// or tag link in the inspector — and "Go to Series" or "More by" in a
    /// book's menu, which has no stack to push onto either — sets this, and
    /// the window's own stack, which exists precisely because the rails and
    /// the detail both push pages, does the pushing.
    ///
    /// A `BookRouter.Route`, the phone's own, so there is one idea of a page
    /// rather than a Mac copy and a translation between the two. Never
    /// `.details`: on the Mac a book's details are this selection
    /// (`BookActions.push`).
    var pushed: BookRouter.Route?

    public init() {}
}

#endif

/// How many library windows the Mac has open: each `MacRootView` counts itself
/// in as it appears and out as it goes.
///
/// For what has to reach a library window from one that is not: a request
/// parked in `AppModel.pendingBook` is taken only by a library window, and
/// with none open it waited — the click that made it did nothing visible,
/// and the request fired whenever a library window next appeared.
@MainActor
@Observable
final class LibraryWindows {
    static let shared = LibraryWindows()
    private(set) var open = 0

    func appeared() { open += 1 }
    func disappeared() { open = max(0, open - 1) }
}

/// "Show in Library" from the Mac's Settings window, which has no library of
/// its own: park the request, open a library window when none is there to
/// take it, and close Settings.
enum ShowInLibrary {
    /// The main window group's id, so a menu can open one.
    static let libraryWindowID = "Library"

    static func opensLibraryWindow(libraryWindowsOpen: Int) -> Bool {
        libraryWindowsOpen == 0
    }
}

/// Routes a book the way each platform expects: a pushed detail screen on
/// iOS and tvOS, and on the Mac a click that selects it into the inspector
/// with a double-click that opens the reader — the label left to the caller so
/// a rail cover, a grid cell and a row can share them. Signed out, the label is
/// inert.
///
/// Signed in, every one carries the book's menu (`.bookMenu`), which is how a
/// rail, a grid and the television's posters all get it without each
/// remembering to.
struct BookLink<Label: View>: View {
    let book: Book
    let session: Session?
    /// The edition a Downloads poster stands for; see `BookMenu.Inputs`.
    var focusEdition: BookContentService.Format?
    var onRemoveFocused: (() -> Void)?
    @ViewBuilder let label: () -> Label
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(MacBookSelection.self) private var selection: MacBookSelection?
    #endif

    init(
        book: Book, session: Session?,
        focusEdition: BookContentService.Format? = nil,
        onRemoveFocused: (() -> Void)? = nil,
        @ViewBuilder label: @escaping () -> Label,
    ) {
        self.book = book
        self.session = session
        self.focusEdition = focusEdition
        self.onRemoveFocused = onRemoveFocused
        self.label = label
    }

    var body: some View {
        if session != nil {
            link.bookMenu(book, focusEdition: focusEdition, onRemoveFocused: onRemoveFocused)
        } else {
            label()
        }
    }

    @ViewBuilder
    private var link: some View {
        #if os(macOS)
        Button {
            // Selecting, where there is an inspector to select into.
            // Without one — a window that has none — a click still opens
            // the book, which is what the Mac did before the inspector
            // existed.
            // Animated for the same reason the toggle is: the first click
            // of a session opens the column, and a panel that appears
            // between two frames reads as a glitch.
            if let selection {
                withAnimation(.snappy(duration: 0.2)) { selection.bookID = book.uuid }
            } else {
                openReader()
            }
        } label: {
            label()
        }
        .buttonStyle(.plain)
        // Double-click still opens the book, because that is what a Mac
        // user expects of a cover and what this app taught them.
        // Simultaneous, so the single click is not held back waiting to see
        // whether a second one arrives.
        .simultaneousGesture(TapGesture(count: 2).onEnded { openReader() })
        .accessibilityAction(named: "Open in reader") { openReader() }
        #elseif os(tvOS)
        // Value-based, so the television declares once — in `TVRootView` —
        // that a book opens the read-along screen. Pushing a destination
        // inline here would mean the shared code naming a view that only
        // the tvOS target has.
        NavigationLink(value: book) {
            label()
        }
        .buttonStyle(.plain)
        #else
        NavigationLink {
            BookDetailView(book: book)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #endif
    }

    #if os(macOS)
    private func openReader() {
        // Keyed by uuid, so a second route to a book already open brings its
        // window forward rather than opening a duplicate.
        openWindow(id: "Reader", value: book.uuid)
    }
    #endif
}

/// Resumes a book where it was left: the pending-book inbox on iOS, which
/// `LibraryTabs.openPendingBook` turns into the reader at the saved position —
/// the path the Continue card, the widget and Handoff all take — and the Reader
/// window on the Mac, which is already resume-first.
///
/// A tap resumes, so the book's own page is the menu's "View details" — and,
/// for VoiceOver, an action of the same name on the row, which reaches it
/// without the menu.
struct ResumeLink<Label: View>: View {
    @Environment(AppModel.self) private var app
    let book: Book
    let session: Session?
    @ViewBuilder let label: () -> Label
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        if session != nil {
            link
                .bookMenu(book)
                .bookDetailsAccessibilityAction(book)
        } else {
            label()
        }
    }

    @ViewBuilder
    private var link: some View {
        #if os(tvOS)
        // A push, not a resume request. `requestBook` sets a pending book
        // that the iOS root view consumes to drive its navigation path;
        // nothing on the television reads it, so pressing this did
        // precisely nothing. The shelf's route is the one that works here.
        NavigationLink(value: book) {
            label()
        }
        .buttonStyle(.plain)
        #else
        Button {
            #if os(macOS)
            openWindow(id: "Reader", value: book.uuid)
            #else
            app.requestBook(book.uuid, .read)
            #endif
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #endif
    }
}

/// A horizontal shelf of covers with a title and, when there is somewhere to
/// go, a "See all". One rail for the detail screen's related books, the
/// Library's Browse screen and the Reading tab's queue, so they cannot drift.
struct BookRail: View {
    @Environment(AppModel.self) private var app
    let title: String
    let books: [Book]
    /// An 84-point cover is a postage stamp across a room. `Metrics.scale` is 2
    /// on tvOS, and this number never went through it.
    #if os(tvOS)
    var coverWidth: CGFloat = 220
    #else
    var coverWidth: CGFloat = 84
    #endif
    /// The series this rail is, when it is one: the book page's rail of the
    /// rest of a series. Its covers then carry their number in it.
    ///
    /// Before `seeAll`, so a caller handing "See all" over as a trailing
    /// closure still binds it.
    var series: String?
    var seeAll: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).overlineStyle()
                Spacer()
                if let seeAll {
                    Button("See all", action: seeAll)
                        .buttonStyle(.plain)
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Palette.tangerinePressed)
                        // The label is short of the 44pt floor; the target is not.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel("See all \(title)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Metrics.spacing12) {
                    ForEach(books) { book in
                        BookLink(book: book, session: app.session) {
                            VStack(alignment: .leading, spacing: Metrics.spacing4) {
                                CoverImage(book: book, session: app.session)
                                    .frame(width: coverWidth)
                                    // A numeral only when the rail is a series.
                                    // Most rails are a cut of the library —
                                    // recently added, tagged, still being read
                                    // — and a numeral on one of their covers
                                    // counts something the row is not about.
                                    // The book page's series rail is about
                                    // exactly that, so there the covers say
                                    // which of the series they are, by the
                                    // rail's series rather than each book's
                                    // own first one: an omnibus numbered in
                                    // its own series first still shows where
                                    // it sits in this one. See `SeriesMark`.
                                    .overlay(alignment: .topLeading) {
                                        SeriesMark(membership: series.flatMap(book.membership(inSeries:)))
                                    }
                                    // The same ring the grid draws, over the
                                    // badge. A rail cover opens the inspector
                                    // too, and without it the reader loses
                                    // track of which cover the column is
                                    // describing.
                                    .overlay { MacSelectionRing(bookID: book.uuid) }
                                Text(book.title)
                                    .font(Typography.caption)
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(2)
                                    .frame(width: coverWidth, alignment: .leading)
                            }
                        }
                    }
                }
            }
            // Edge to edge, with the margin put back as a content inset. Inside
            // the screen's padding the rail was clipped 16pt short of the
            // glass, so a shelf that continues off-screen looked like one that
            // had been cut off. The filter chips already do this.
            .scrollClipDisabled()
            .padding(.horizontal, -Metrics.screenMargin)
            .contentMargins(.horizontal, Metrics.screenMargin, for: .scrollContent)
            // Says out loud that this one is meant to reach the screen edge.
            // The sweep has to be told which containers bleed on purpose,
            // rather than inferring it and being wrong in both directions.
            .accessibilityIdentifier("rail.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
        }
    }
}
