import IssaCore
import IssaUI
import SwiftUI

/// Where a book's menu sends the reader, on the screen the menu was opened on.
///
/// One per screen, installed by `.bookRoutes(place:)`, and found by the menu
/// through the environment — the pattern `MacBookSelection` uses, for the same
/// reason: the cells that draw covers are shared by every screen and should not
/// be handed a navigation path to know how to leave one.
///
/// A menu item cannot be a `NavigationLink`, so its navigation has to be
/// imperative, and the obvious imperative route — `AppModel.requestBook` —
/// is the deep-link inbox: `LibraryTabs.openPendingBook` empties the tab's
/// path before it pushes, so "View details" on the third screen of a stack
/// would throw the first two away. Most screens are pushed by
/// `NavigationLink(destination:)`, which never appears in a path at all, so
/// appending to one is no better. A destination declared on the screen itself
/// pushes on top of that screen and keeps the back stack, which is what a
/// reader expects of a menu.
@MainActor
@Observable
final class BookRouter {
    enum Route: Hashable, Identifiable {
        case details(Book)
        case series(String)
        case author(String)
        case tag(String)

        var id: Self { self }
    }

    /// The screen to push on top of this one (iPhone and iPad).
    var route: Route?
    /// The full player, for "Now Playing" (iPhone and iPad).
    var showsPlayer = false
    /// Something a menu item tried and could not do.
    var alert: BookAlert?
}

/// A failure worth telling the reader about: a Listen that could not start, a
/// download the Wi-Fi rule held back. Said in an alert because the menu that
/// asked for it has already closed, and the screen under it has nowhere of its
/// own to say it.
struct BookAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

extension View {
    /// Installs this screen's `BookRouter` and says which screen it is, so a
    /// book's menu offers neither the way to here nor a route it cannot take.
    func bookRoutes(place: BookMenu.Place) -> some View {
        modifier(BookRoutes(place: place))
    }
}

private struct BookRoutes: ViewModifier {
    let place: BookMenu.Place
    @Environment(AppModel.self) private var app
    @State private var router = BookRouter()

    func body(content: Content) -> some View {
        content
            .environment(router)
            .environment(\.bookPlace, place)
            #if os(iOS)
            .navigationDestination(item: $router.route) { route in
                Self.destination(for: route)
            }
            .sheet(isPresented: $router.showsPlayer) { NowPlayingSheet() }
            // A deep link resets the tab's path and pushes its own book. A page
            // this router pushed is not in that path, so it is taken down here
            // rather than left for the reset to reconcile with.
            .onChange(of: app.pendingBook) { _, pending in
                if pending != nil { router.route = nil }
            }
            // Nothing to expand into once playback has stopped.
            .onChange(of: app.playback == nil) { _, stopped in
                if stopped { router.showsPlayer = false }
            }
            #endif
            .alert(
                router.alert?.title ?? "",
                isPresented: Binding(
                    get: { router.alert != nil },
                    set: { if !$0 { router.alert = nil } }),
                presenting: router.alert,
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { alert in
                Text(alert.message)
            }
    }

    @ViewBuilder
    static func destination(for route: BookRouter.Route) -> some View {
        switch route {
        case let .details(book): BookDetailView(book: book)
        case let .series(name): SeriesView(name: name)
        case let .author(name): AuthorView(name: name)
        case let .tag(name): TagView(name: name)
        }
    }
}

/// A request to show the library's own grid, made from a page that cannot get
/// there by itself.
///
/// "Show in Library" on a tag or author page means the Library tab's root —
/// or, on the Mac, the All books shelf — and only the platform's root view can
/// switch tabs or empty a stack it did not build. So the page asks here and the
/// root answers, the way a deep link asks `AppModel` and `openPendingBook`
/// answers: by rebuilding the library's stack from its root, since most pages
/// are pushed by `NavigationLink(destination:)` and no path holds them. One
/// for the process, as `AppModel` is one for the process.
@MainActor
@Observable
final class LibraryNavigator {
    static let shared = LibraryNavigator()

    /// Bumped by each request; the platform root goes to the library grid.
    private(set) var showRequests = 0
    /// A search for the library to run when it next appears, for an author's
    /// "Show in Library": the library has no author filter, and its search
    /// already looks through authors.
    var pendingSearch: String?

    func showLibrary(search: String? = nil) {
        pendingSearch = search
        showRequests &+= 1
    }
}
