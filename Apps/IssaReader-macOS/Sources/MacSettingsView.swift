import IssaCore
import IssaUI
import SwiftUI

/// The Mac's Settings window, behind ⌘,.
///
/// The same screens as the phone's Settings tab, arranged as tabs rather than a
/// pushed list — a Mac reader expects preferences in a window, not a navigation
/// stack.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            ReadingSettingsView()
                .tabItem { Label("Reading", systemImage: "textformat") }
            ControlsSettingsView()
                .tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            AccountSettingsView()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
        }
        .background(Palette.paper)
    }
}

/// Signing out, and what the server is — the two account facts worth a screen.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            if let session = app.session, case let .signedIn(user) = session.state {
                LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                LabeledContent("Server", value: session.serverURL.absoluteString)
            }
            Section {
                Button("Sign Out…", role: .destructive) { confirmingSignOut = true }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.paper)
        .confirmationDialog(
            "Sign out of Issa Reader?",
            isPresented: $confirmingSignOut, titleVisibility: .visible,
        ) {
            Button("Sign Out and Keep Downloads") {
                Task { await app.signOut(keepDownloads: true, nowPlaying: nowPlaying) }
            }
            Button("Sign Out and Delete Downloads", role: .destructive) {
                Task { await app.signOut(nowPlaying: nowPlaying) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded books stay on this Mac unless you remove them.")
        }
    }
}
