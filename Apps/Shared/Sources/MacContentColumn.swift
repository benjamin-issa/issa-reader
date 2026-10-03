import Foundation
import IssaCore

// The Mac library window's sidebar and content column, as plain values.
//
// Compiled on every platform so the iPhone-hosted tests can ask them, the way
// `LibraryModeSwitch` and `MacFileMenu` are: the Mac window calls these, and
// no test can drive its windows.

/// The Mac library window's sidebar entries. Shelves come from the same
/// definition the phone filters by, so the two never drift apart.
enum MacSidebar: Hashable {
    case reading
    case shelf(LibraryArrangement.Shelf)
    case listening
    case downloads

    var title: String {
        switch self {
        case .reading: "Reading"
        case let .shelf(shelf): shelf.title
        case .listening: "Listening"
        case .downloads: "Downloads"
        }
    }

    var symbol: String {
        switch self {
        // Not `bookmark` or `book`: those are the To read and Reading
        // shelves' glyphs two rows down.
        case .reading: "text.book.closed"
        case .shelf(.all): "books.vertical"
        case .shelf(.reading): "book"
        case .shelf(.toRead): "bookmark"
        case .shelf(.finished): "checkmark.circle"
        case .shelf(.downloaded): "arrow.down.circle"
        case .shelf(.withNarration): "waveform"
        case .listening: "headphones"
        case .downloads: "internaldrive"
        }
    }

    var isShelf: Bool {
        if case .shelf = self { true } else { false }
    }
}

/// What the Mac library window's content column shows: the sidebar's row, and
/// the pages pushed over it.
///
/// The pages are a path the window's stack is bound to, and taken down by
/// emptying it. They used to be a `navigationDestination(item:)` on a stack
/// rebuilt with `.id(selection)` for every sidebar change — and on macOS 27 a
/// stack in a `NavigationSplitView`'s detail column is the column's own, so a
/// rebuilt stack left the old one's page standing: a tag page opened from the
/// Reading screen stayed up under a sidebar that said All books, and once the
/// sidebar had moved at all, "Show in Library" applied its filter beneath a
/// page that never left (F4, F5).
///
/// One value for both halves, so a sidebar change and the page it takes down
/// happen in the same write rather than in two `onChange`s whose order
/// SwiftUI does not promise.
struct MacContentColumn: Equatable {
    private(set) var selection: MacSidebar? = .shelf(.all)
    /// The pages over the row, bound to the stack. Back pops it.
    var path: [BookRouter.Route] = []

    /// A sidebar row: its own root, nothing left pushed from the last one.
    mutating func select(_ row: MacSidebar?) {
        guard row != selection else { return }
        selection = row
        path = []
    }

    /// A page a link or a book's menu asked for. Never a book's details,
    /// which on the Mac are the inspector (`BookActions.push`), and not the
    /// page already on top — a second click on the same chip.
    mutating func push(_ route: BookRouter.Route) {
        if case .details = route { return }
        guard path.last != route else { return }
        path.append(route)
    }

    /// "Show in Library" from a tag or author page: the All books grid, with
    /// the filter or search the page has set, and no page left over it.
    mutating func showLibrary() {
        selection = .shelf(.all)
        path = []
    }

    /// A book asked for in the inspector from outside the window — Settings'
    /// "Show in Library", a link, Spotlight: the library, with no page over
    /// it, on the shelf the reader is on when the book is on it and on All
    /// books otherwise.
    mutating func revealBook(isOnCurrentShelf: Bool) {
        path = []
        if !(selection?.isShelf ?? false) || !isOnCurrentShelf {
            selection = .shelf(.all)
        }
    }
}
