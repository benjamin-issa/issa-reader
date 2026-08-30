import IssaCore
import IssaUI
import SwiftUI

@main
struct IssaReaderApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
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
