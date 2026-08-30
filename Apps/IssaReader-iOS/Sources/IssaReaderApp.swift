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

    var body: some View {
        TabView {
            NavigationStack {
                LibraryView().navigationTitle("Library")
            }
            .tabItem { Label("Library", systemImage: "books.vertical") }

            NavigationStack {
                ListeningView().navigationTitle("Listening")
            }
            .tabItem { Label("Listening", systemImage: "headphones") }

            NavigationStack {
                SettingsView().navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        // Above the tab bar, so an audiobook started on one screen can still be
        // paused from any other.
        .safeAreaInset(edge: .bottom, spacing: 0) { MiniPlayer() }
    }
}
