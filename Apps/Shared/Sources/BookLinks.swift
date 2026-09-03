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
    public var bookID: String?
    public init() {}
}

#endif

/// Routes a book the way each platform expects: a pushed detail screen on
/// iOS and tvOS, and on the Mac a click that selects it into the inspector
/// with a double-click that opens the reader — the label left to the caller so
/// a rail cover, a grid cell and a row can share them. Signed out, the label is
/// inert.
struct BookLink<Label: View>: View {
    let book: Book
    let session: Session?
    @ViewBuilder let label: () -> Label
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(MacBookSelection.self) private var selection: MacBookSelection?
    #endif

    var body: some View {
        if session != nil {
            #if os(macOS)
            Button {
                // Selecting, where there is an inspector to select into.
                // Without one — a window that has none — a click still opens
                // the book, which is what the Mac did before the inspector
                // existed.
                if let selection { selection.bookID = book.uuid } else { openReader() }
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
            #else
            NavigationLink {
                BookDetailView(book: book)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            #endif
        } else {
            label()
        }
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
        } else {
            label()
        }
    }
}

/// A horizontal shelf of covers with a title and, when there is somewhere to
/// go, a "See all". One rail for the detail screen's related books, the
/// Library's Browse screen and the Reading tab's queue, so they cannot drift.
struct BookRail: View {
    @Environment(AppModel.self) private var app
    let title: String
    let books: [Book]
    var coverWidth: CGFloat = 84
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
                                CoverImage(book: book, session: app.session).frame(width: coverWidth)
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
        }
    }
}
