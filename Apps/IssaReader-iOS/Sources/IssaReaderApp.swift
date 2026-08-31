import CoreSpotlight
import IssaCore
import IssaUI
import SwiftUI

@main
@MainActor
struct IssaReaderApp: App {
    /// Only so that `AppServices.start()` runs when the *car* is what launched
    /// the app. There is no other reason for a delegate here.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    private let services = AppServices.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(services.app)
                .environment(services.settings)
                .environment(services.nowPlaying)
                // Idempotent, and belt-and-braces: the delegate has normally
                // run by now, but a scene that somehow arrives first must not
                // find an unstarted app.
                .task { AppServices.shared.start() }
                // CarPlay's list is built from whatever the bridge holds, and
                // the car can connect before the phone app has ever loaded a
                // library — so it is refreshed whenever the library changes
                // rather than only at connect.
                .onChange(of: services.app.books) { _, books in
                    CarPlayBridge.shared.update(
                        books: books, downloaded: services.app.downloadedUUIDs)
                }
                .onChange(of: services.app.downloadedUUIDs) { _, downloaded in
                    CarPlayBridge.shared.update(
                        books: services.app.books, downloaded: downloaded)
                }
                .tint(Palette.tangerine)
                .onOpenURL { services.app.open($0) }
                // A Spotlight result carries the book's uuid as its identifier,
                // which is the same handle a deep link uses.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    services.app.pendingBookID = id
                }
                .onContinueUserActivity(BookActivity.type) { activity in
                    guard let id = activity.userInfo?[BookActivity.bookIDKey] as? String else { return }
                    services.app.pendingBookID = id
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .launching:
                // Deliberately no content — but painted in the app's own ground
                // so the launch image, this, and the library are one continuous
                // colour. A returning reader never sees the sign-in form flash
                // past on the way to their shelf.
                Palette.paper.ignoresSafeArea()
            case .chooseServer, .signingIn, .expired:
                SignInView()
            case .ready:
                LibraryTabs()
            }
        }
        // The session is restored by `AppServices.start()`, so that a car
        // connecting to a never-foregrounded app finds one.
        .task { await app.watchForExpiry() }
    }
}

/// Library, Playing and Settings.
///
/// There was once a Listening tab over the same catalogue minus the text-only
/// books, which testers read as two libraries rather than one filtered view.
/// Its job is a shelf chip now. The Playing tab is a different thing: not
/// another way to browse, but the one place the expanded player lives, which
/// the mini bar opens into.
/// (`ListeningView` stays — the macOS sidebar and tvOS still use it.)
struct LibraryTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryPath = NavigationPath()
    @State private var selectedTab = Tab.library

    enum Tab: Hashable { case library, playing, settings }

    private func openPendingBook() {
        guard let book = app.consumePendingBook() else { return }
        selectedTab = .library
        libraryPath = NavigationPath()
        libraryPath.append(book)
    }

    private var tabs: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $libraryPath) {
                LibraryView()
                    .navigationTitle("Library")
                    .navigationDestination(for: Book.self) { book in
                        BookDetailView(book: book)
                    }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(Tab.library)

            NavigationStack {
                NowPlayingTab().navigationTitle("Playing")
            }
            .tabItem { Label("Playing", systemImage: "play.circle") }
            .tag(Tab.playing)

            NavigationStack {
                SettingsView().navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
    }

    /// The tab bar's accessory slot, which is what iOS 26 provides for exactly
    /// this. As a `.safeAreaInset` the mini player was drawn over the floating
    /// tab bar rather than above it, so starting an audiobook hid Library and
    /// Settings entirely.
    ///
    /// It has to be gated on there being something to show. The slot is placed
    /// whether or not its content draws anything, so a `MiniPlayer` that
    /// returned nothing still got a glass capsule at its minimum height, plus
    /// the bottom safe area it reserves — an empty second bar above the tab bar
    /// on every screen, with the library scrolling behind it.
    ///
    /// `isEnabled:` arrived in iOS 26.1 and the deployment target is 26.0, so
    /// the older path applies the modifier conditionally instead. `#available`
    /// is fixed for the life of the process, so the branch it picks never
    /// changes and the 26.1 path never churns view identity; only the fallback
    /// can, and losing the library's scroll position when playback starts is
    /// still better than a bar that is always there and always empty.
    @ViewBuilder
    private var shell: some View {
        if #available(iOS 26.1, *) {
            tabs.tabViewBottomAccessory(isEnabled: app.playback != nil) { miniPlayer }
        } else if app.playback != nil {
            tabs.tabViewBottomAccessory { miniPlayer }
        } else {
            tabs
        }
    }

    private var miniPlayer: some View {
        MiniPlayer { selectedTab = .playing }
    }

    var body: some View {
        shell
        // A link can arrive before the library has loaded, so this waits for
        // the book to exist rather than dropping the request on the floor.
        .onChange(of: app.pendingBookID) { openPendingBook() }
        .onChange(of: app.books) { openPendingBook() }
        // Indexed off the main path: a large library should not delay the
        // first frame to make itself searchable.
        .task(id: app.books.count) { await SpotlightIndex.index(app.books) }
        .task { openPendingBook() }
        // An intent runs outside the scene and cannot navigate, so it leaves
        // the book in an inbox for the scene to collect when it appears.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // A download can finish while the app is in the background, and the
            // finish hook only fires in-process.
            app.refreshDownloadedSet()
            guard let id = AppIntentInbox.shared.bookID else { return }
            AppIntentInbox.shared.bookID = nil
            app.pendingBookID = id
        }
    }
}
