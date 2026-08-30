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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(settings)
                .environment(nowPlaying)
                .task { nowPlaying.configure(settings: settings) }
                .tint(Palette.tangerine)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            switch app.phase {
            case .chooseServer, .signingIn:
                SignInView()
            case .ready:
                LibraryTabs()
            }
        }
        .task { await app.restoreIfPossible() }
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
    }
}
