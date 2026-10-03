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
            AdvancedSettingsView()
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .background(Palette.paper)
        // The window's own undo toast: the Downloads tab's rows and their
        // menus remove downloads here, where the library window's toast
        // cannot be seen. See `downloadRemovalToast`.
        .downloadRemovalToast()
    }
}

/// Signing out, and what the server is — the two account facts worth a screen.
struct AccountSettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @State private var confirmingSignOut = false
    /// True from the confirmation until the sign-out has finished, for the
    /// app rather than this pane: see `SignOutProgress`.
    private var isSigningOut: Bool { SignOutProgress.shared.isRunning }

    var body: some View {
        Form {
            if let session = app.session, case let .signedIn(user) = session.state {
                LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                LabeledContent("Server", value: session.serverURL.absoluteString)
            }
            Section {
                // Held off while one is under way, as on the phone: signing
                // out tells the server first and waits up to the logout's own
                // limit for an answer, and in those seconds nothing here
                // changed and Sign Out could start a second sign-out behind
                // the first.
                Button(isSigningOut ? "Signing Out…" : "Sign Out…", role: .destructive) {
                    confirmingSignOut = true
                }
                .disabled(isSigningOut)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Palette.paper)
        .confirmationDialog(
            "Sign out of Issa Reader?",
            isPresented: $confirmingSignOut, titleVisibility: .visible,
        ) {
            Button("Sign Out and Keep Downloads") { signOut(keepDownloads: true) }
                .disabled(isSigningOut)
            Button("Sign Out and Delete Downloads", role: .destructive) {
                signOut(keepDownloads: false)
            }
            .disabled(isSigningOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded books stay on this Mac unless you remove them.")
        }
    }

    private func signOut(keepDownloads: Bool) {
        Task { [app, nowPlaying] in
            await SignOutProgress.shared.run {
                await app.signOut(keepDownloads: keepDownloads, nowPlaying: nowPlaying)
            }
        }
    }
}

/// Server internals and log export.
///
/// A tab rather than the everyday four, because these serve self-hosting and
/// support rather than reading. Nothing is removed — the same rows the phone
/// keeps under its Advanced disclosure, from the same view.
struct AdvancedSettingsView: View {
    var body: some View {
        // Its own stack: "Export logs" pushes, and a Settings tab has no
        // navigation container of its own.
        NavigationStack {
            List {
                AdvancedSettingsRows()
                    .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.paper)
        }
    }
}
