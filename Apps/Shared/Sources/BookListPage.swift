import IssaCore
import IssaUI
import SwiftUI

/// Every book carrying one tag, reached from a tag chip on a book's page.
///
/// Looked up by name on every body, as `SeriesView` does: the page is a cut of
/// the live catalogue, so a status set from a book's menu here moves the book
/// between sections at once, and a tag the server has since removed says so
/// rather than showing a stale list.
struct TagView: View {
    @Environment(AppModel.self) private var app
    let name: String

    var body: some View {
        // The memoised grouping for which books, each resolved through the
        // index a position moves, so progress and recency stay live.
        BookListPage(subject: .tag(name), books: (app.booksByTag[name] ?? []).map {
            app.bookByUUID[$0.uuid] ?? $0
        })
    }
}

/// "More by ‹author›": every book by one author, from a book's menu. The tag
/// page's layout, with the author's name where the tag's would be.
struct AuthorView: View {
    @Environment(AppModel.self) private var app
    let name: String

    var body: some View {
        BookListPage(subject: .author(name), books: (app.booksByAuthor[name] ?? []).map {
            app.bookByUUID[$0.uuid] ?? $0
        })
    }
}

/// The page a tag and an author share: the name set large, one summary line,
/// and the books grouped by reading stage (`StagedBooks`).
///
/// A focused cut of the library rather than a second library: no sort
/// control — the grouping is the order a reader chooses their next book in —
/// and "Show in Library" for everything the full grid can do.
struct BookListPage: View {
    enum Subject: Equatable {
        case tag(String)
        case author(String)

        var name: String {
            switch self {
            case let .tag(name), let .author(name): name
            }
        }

        /// What VoiceOver calls the page's subject after its name.
        var kind: String {
            switch self {
            case .tag: "tag"
            case .author: "author"
            }
        }

        var place: BookMenu.Place {
            switch self {
            case let .tag(name): .tag(name)
            case let .author(name): .author(name)
            }
        }

        var identifier: String {
            switch self {
            case .tag: "tag"
            case .author: "author"
            }
        }
    }

    @Environment(AppModel.self) private var app
    let subject: Subject
    let books: [Book]

    /// How far the page has scrolled from rest, and where the header's name
    /// ends, both in the content's own points.
    @State private var scrolled: CGFloat = 0
    @State private var nameBottom: CGFloat = .greatestFiniteMagnitude

    var body: some View {
        let staged = StagedBooks(books: books, statuses: app.statuses)
        ScrollView {
            if !staged.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    BookListHeader(
                        subject: subject, staged: staged, showInLibrary: showInLibrary,
                        nameBottom: $nameBottom)
                    VStack(alignment: .leading, spacing: Metrics.spacing32) {
                        ForEach(staged.sections) { section in
                            StageSection(
                                section: section, showsOverline: staged.showsOverlines,
                                caption: caption)
                        }
                    }
                    .padding(.top, Metrics.spacing8)
                }
                .coordinateSpace(name: BookListHeader.space)
                // Before the padding, as on the book page: this container's
                // frame is what the sweep measures the margin against.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("content.\(subject.identifier)")
                .padding(.horizontal, Metrics.screenMargin)
                .padding(.bottom, Metrics.screenMargin)
            } else {
                // Inside the scroll view, so pull to refresh still works, and
                // the size of what is visible of it: an empty scroll view
                // collapses to its content, and the message came out as a
                // column of one word per line on a ground with no paper.
                emptyState
                    .containerRelativeFrame([.horizontal, .vertical])
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            scrolled = offset
        }
        .accessibilityIdentifier("screen.\(subject.identifier)")
        .background(Palette.paper)
        .navigationTitle(subject.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // The bar's title stays out of the way while the header says the same
        // name in large type beneath it, and comes in once that has scrolled
        // under the bar — the name printed twice at the top otherwise. With no
        // books there is no header, so the bar carries it throughout.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(subject.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(staged.isEmpty || scrolled >= nameBottom ? 1 : 0)
                    .animation(.easeInOut(duration: 0.2), value: scrolled >= nameBottom)
                    // The header already reads the name, as a heading.
                    .accessibilityHidden(!staged.isEmpty)
            }
        }
        #endif
        .refreshable { await app.refreshLibrary() }
        .bookRoutes(place: subject.place)
    }

    /// The author page's line under a cover, where the byline would only
    /// repeat the page's title. The tag page keeps the byline.
    private var caption: ((Book) -> String?)? {
        switch subject {
        case .tag: nil
        case .author: { StagedBooks.authorCaption(for: $0) }
        }
    }

    /// The page can outlive its books: a refresh can take a tag off every
    /// book that had it. Back is right there, so it offers nothing else.
    private var emptyState: some View {
        let (symbol, title, message) = switch subject {
        case let .tag(name): (
            "tag", "No books with this tag",
            "Nothing in your library carries “\(name)” any more. It may have been removed on the server.")
        case let .author(name): (
            "person", "No books by this author",
            "Nothing in your library is by \(name) any more. It may have been removed on the server.")
        }
        return PalettePlaceholder(symbol: symbol, title: title, message: message)
            .accessibilityElement(children: .combine)
    }

    /// The library's own grid, filtered here rather than rebuilt: every sort
    /// and shelf the grid has is then one tap away. The platform's root
    /// answers the request: the Library tab at its root on the phone, the
    /// All books grid on the Mac.
    private func showInLibrary() {
        switch subject {
        case let .tag(name):
            app.showAllBooks(shelf: .all, tags: [name])
            LibraryNavigator.shared.showLibrary()
        case let .author(name):
            app.showAllBooks(shelf: .all)
            LibraryNavigator.shared.showLibrary(search: name)
        }
    }
}

/// The page's name, set large, and the one line that says what is in it.
struct BookListHeader: View {
    nonisolated static let space = "bookListPage"

    let subject: BookListPage.Subject
    let staged: StagedBooks
    let showInLibrary: () -> Void
    /// Where the name ends, for the bar's title to come in once it has gone.
    @Binding var nameBottom: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing4) {
            Text(subject.name)
                .font(Typography.display)
                .foregroundStyle(Palette.ink)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(Self.space)).maxY
                } action: { nameBottom = $0 }
                // One element for the whole header, read as a heading: the
                // name, what it is, and the count.
                .accessibilityLabel(staged.spokenHeader(name: subject.name, kind: subject.kind))
                .accessibilityAddTraits(.isHeader)
            // The summary and the link share a line while they fit, and stack
            // when they do not — at accessibility sizes, or a narrow Mac column.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Metrics.spacing8) {
                    summary
                    Spacer(minLength: Metrics.spacing8)
                    link
                }
                VStack(alignment: .leading, spacing: 0) {
                    summary
                    link
                }
            }
            #if !os(macOS)
            .frame(minHeight: 44)
            #endif
        }
    }

    private var summary: some View {
        Text(staged.summary)
            .font(Typography.footnote)
            .foregroundStyle(Palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            // In the header's own label.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var link: some View {
        if staged.offersShowInLibrary {
            Button("Show in Library", action: showInLibrary)
                .buttonStyle(.plain)
                .font(Typography.caption.weight(.semibold))
                .foregroundStyle(Palette.tangerinePressed)
                #if !os(macOS)
                // The label is short of the 44pt floor; the target is not.
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
                #endif
                .accessibilityHint(subject.kind == "tag"
                    ? "Shows the whole library, filtered to this tag"
                    : "Shows the whole library, searched for this author")
        }
    }
}

/// One reading stage: an overline with its count, then the library's own grid.
struct StageSection: View {
    let section: StagedBooks.Section
    let showsOverline: Bool
    let caption: ((Book) -> String?)?
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            if showsOverline {
                Text(section.overline)
                    .overlineStyle()
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(section.spokenOverline)
                    .accessibilityAddTraits(.isHeader)
            }
            if dynamicTypeSize.isAccessibilitySize {
                rows
            } else {
                // No series: a tag is not a series, so no numerals on covers.
                BookGrid(books: section.books, session: app.session, caption: caption)
            }
        }
    }

    /// At accessibility sizes a grid of covers leaves each title a word per
    /// line, so the section becomes a list: a rail-sized cover beside words
    /// that wrap as far as they need to.
    private var rows: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing24) {
            ForEach(section.books) { book in
                BookLink(book: book, session: app.session) {
                    HStack(alignment: .top, spacing: Metrics.spacing16) {
                        BookCell(book: book, session: app.session).coverBlock
                            .frame(width: 84)
                        VStack(alignment: .leading, spacing: Metrics.spacing4) {
                            Text(book.title)
                                .font(Typography.subhead)
                                .foregroundStyle(Palette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(caption?(book) ?? book.byline)
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("cell.book.\(book.uuid)")
            }
        }
    }
}
