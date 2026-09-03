import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(NowPlayingController.self) private var nowPlaying
    @Environment(PlaybackSettings.self) private var settings
    @State private var confirmingSignOut = false

    public init() {}

    public var body: some View {
        list
            // The design commits to warm paper everywhere; a stock grouped List
            // would reintroduce system grey behind and between the rows.
            .paperListBackground()
    }

    private var list: some View {
        @Bindable var settings = settings

        return List {
            if let session = app.session, case let .signedIn(user) = session.state {
                Section("Account") {
                    LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                    LabeledContent("Server", value: session.serverURL.absoluteString)
                }
                .listRowBackground(Palette.surface)

                Section {
                    LabeledContent("Books", value: "\(app.books.count)")
                    LabeledContent("With narration", value: "\(app.derivation.readalongs.count)")
                } header: {
                    Text("Library")
                }
                .listRowBackground(Palette.surface)
            }

            Section {
                // Inline rather than a level down: it is one control, and the
                // people who want it are the ones staring at a five-hour bar
                // wondering where their chapter is.
                Picker("Progress bar", selection: $settings.progressScope) {
                    ForEach(ProgressScope.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                NavigationLink { ControlsSettingsView() } label: {
                    Label("Controls & remapping", systemImage: "slider.horizontal.3")
                        .labelStyle(.gapped)
                }
                NavigationLink { ReadingSettingsView() } label: {
                    Label("Reading & highlights", systemImage: "textformat")
                        .labelStyle(.gapped)
                }
                NavigationLink { DownloadsView() } label: {
                    Label("Downloads & storage", systemImage: "arrow.down.circle")
                        .labelStyle(.gapped)
                }
            } header: {
                Text("Playback & reading")
            } footer: {
                Text(settings.progressScope == .chapter
                    ? "The player, the Lock Screen and CarPlay all show the chapter you are in."
                    : "The player, the Lock Screen and CarPlay all show the whole book.")
            }
            .listRowBackground(Palette.surface)

            // Server internals and log export serve self-hosters and support,
            // not the general reader, so they collapse one tap down rather than
            // competing with Account / Library / Playback for attention.
            Section {
                // tvOS has no `DisclosureGroup`; it shows the same rows under a
                // plain "Advanced" heading (still one section down, off the main
                // path), while iOS and the Mac collapse them.
                #if os(tvOS)
                Text("Advanced").overlineStyle()
                advancedContent
                #else
                DisclosureGroup("Advanced") {
                    advancedContent
                }
                #endif
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Sign out", role: .destructive) { confirmingSignOut = true }
            }
            .listRowBackground(Palette.surface)
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                // Downloaded books are expensive to fetch again, so this is a
                // choice rather than an assumption.
                Button("Sign out and keep downloads") { Task { await app.signOut(keepDownloads: true, nowPlaying: nowPlaying) } }
                Button("Sign out and delete downloads", role: .destructive) {
                    Task { await app.signOut(keepDownloads: false, nowPlaying: nowPlaying) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    /// The rows behind "Advanced": server capabilities (for self-hosters) and
    /// log export (for support). Factored out so iOS/macOS can put them in a
    /// `DisclosureGroup` and tvOS can list them inline.
    @ViewBuilder private var advancedContent: some View {
        AdvancedSettingsRows()
    }
}

/// What "Advanced" holds, wherever it is shown.
///
/// Its own view so the Mac's Advanced tab and the phone's disclosure render the
/// same rows rather than two lists that drift.
struct AdvancedSettingsRows: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let session = app.session, case .signedIn = session.state {
            // Surfacing this makes it obvious which server generation is in
            // play, and why some rails are computed locally.
            Text("Server capabilities")
                .overlineStyle()
            capabilityRow("Home sections", session.capabilities.homeSections)
            capabilityRow("Shelves", session.capabilities.shelves)
            capabilityRow("Library facets", session.capabilities.libraryFacets)
            capabilityRow("Server discovery", session.capabilities.serverDiscovery)
            Text("Features your server does not provide are computed on this device instead.")
                .font(Typography.footnote)
                .foregroundStyle(Palette.inkTertiary)
        }
        NavigationLink { DiagnosticsView() } label: {
            Label("Export logs", systemImage: "doc.text.magnifyingglass")
                        .labelStyle(.gapped)
        }
    }

    private func capabilityRow(_ name: String, _ available: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Palette.moss : Palette.inkQuaternary)
        }
    }
}
