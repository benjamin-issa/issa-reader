import CoreSpotlight
import IssaCore
import IssaUI
import SwiftUI

@main
struct IssaReaderApp: App {
    @State private var app = AppModel()
    @State private var settings = PlaybackSettings()
    @State private var nowPlaying = NowPlayingController()

    init() {
        // Package-bundled fonts are not registered automatically the way an
        // app's UIAppFonts entry would be, so this must run before first render.
        IssaFonts.register()
        // Early builds put downloads in Caches, which iOS purges.
        BookContentService.migrateFromCachesIfNeeded()
    }

    /// Hands CarPlay the three things it cannot reach on its own: the library,
    /// somewhere to start a book, and which surface the controls belong to.
    @MainActor
    private func connectCarPlay() {
        let bridge = CarPlayBridge.shared
        bridge.update(books: app.books)
        bridge.onPlay = { [app, settings, nowPlaying] bookID in
            guard let book = app.books.first(where: { $0.uuid == bookID }) else { return }
            Task { await app.startListening(to: book, nowPlaying: nowPlaying, settings: settings) }
        }
        bridge.onCycleRate = { [settings, nowPlaying] in
            // Through the rates a driver actually wants, wrapping around: there
            // is no keyboard in a car and no menu on the Now Playing template.
            let rates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]
            let current = settings.playbackRate
            let next = rates.first { $0 > current + 0.01 } ?? rates[0]
            settings.playbackRate = next
            nowPlaying.coordinator?.player.rate = Float(next)
            nowPlaying.publish()
        }
        bridge.onSurfaceChange = { [nowPlaying] surface in
            nowPlaying.setSurface(surface)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task { nowPlaying.configure(settings: settings) }
                .task { connectCarPlay() }
                // CarPlay's list is built from whatever the bridge holds, and
                // the car can connect before the phone app has ever loaded a
                // library — so it is refreshed whenever the library changes
                // rather than only at connect.
                .onChange(of: app.books) { _, books in CarPlayBridge.shared.update(books: books) }
                .tint(Palette.tangerine)
                .onOpenURL { app.open($0) }
                // A Spotlight result carries the book's uuid as its identifier,
                // which is the same handle a deep link uses.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String
                    else { return }
                    app.pendingBookID = id
                }
                .onContinueUserActivity(BookActivity.type) { activity in
                    guard let id = activity.userInfo?[BookActivity.bookIDKey] as? String else { return }
                    app.pendingBookID = id
                }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .chooseServer, .signingIn, .expired:
                SignInView()
            case .ready:
                LibraryTabs()
            }
        }
        .task { await app.restoreIfPossible() }
        .task { await app.watchForExpiry() }
    }
}

/// The design's three-tab structure: Library, Listening, Settings.
struct LibraryTabs: View {
    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var libraryPath = NavigationPath()
    @State private var selectedTab = 0

    private func openPendingBook() {
        guard let book = app.consumePendingBook() else { return }
        selectedTab = 0
        libraryPath = NavigationPath()
        libraryPath.append(book)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $libraryPath) {
                LibraryView()
                    .navigationTitle("Library")
                    .navigationDestination(for: Book.self) { book in
                        BookDetailView(book: book)
                    }
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }
            .tag(0)

            NavigationStack {
                ListeningView().navigationTitle("Listening")
            }
            .tabItem { Label("Listening", systemImage: "headphones") }
            .tag(1)

            NavigationStack {
                SettingsView().navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(2)
        }
        // Above the tab bar, so an audiobook started on one screen can still be
        // paused from any other.
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
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
            guard phase == .active, let id = AppIntentInbox.shared.bookID else { return }
            AppIntentInbox.shared.bookID = nil
            app.pendingBookID = id
        }
    }
}
