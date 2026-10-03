#if os(iOS)
import IssaCore
import IssaPlayback
import IssaUI
import SwiftUI

/// Settings for a reader with no server: the same groups, fewer rows.
///
/// Opened by the gearshape on the standalone list. Account, Library,
/// Downloads & storage, Ask and Advanced are left out — each needs a server.
/// Playback & reading is the same as everywhere else, and applies to the books
/// on this device too. "On this iPhone" stands where Library would, and Server
/// holds the way back.
struct LocalSettingsSheet: View {
    @Environment(LocalLibrary.self) private var library
    @Environment(PlaybackSettings.self) private var settings
    @Environment(LocalBooksRoute.self) private var route: LocalBooksRoute?
    @Environment(\.dismiss) private var dismiss
    @State private var spaceUsed: Int64?

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            List {
                Section {
                    LabeledContent("Books", value: "\(library.books.count)")
                    LabeledContent("Space used", value: spaceUsed.map(ByteCountText.text) ?? "—")
                } header: {
                    Text("On this \(LocalDevice.noun)")
                }
                .listRowBackground(Palette.surface)

                Section {
                    Picker("Progress bar", selection: $settings.progressScope) {
                        ForEach(ProgressScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    NavigationLink { ControlsSettingsView() } label: {
                        Label("Controls & remapping", systemImage: "slider.horizontal.3").labelStyle(.gapped)
                    }
                    NavigationLink { ReadingSettingsView() } label: {
                        Label("Reading & highlights", systemImage: "textformat").labelStyle(.gapped)
                    }
                } header: {
                    Text("Playback & reading")
                }
                .listRowBackground(Palette.surface)

                Section {
                    Button {
                        dismiss()
                        route?.showsListSignedOut = false
                    } label: {
                        Text("Connect to a Storyteller server")
                            .foregroundStyle(Palette.tangerinePressed)
                    }
                    .accessibilityIdentifier("settings.connectToServer")
                } header: {
                    Text("Server")
                } footer: {
                    Text("Library, sync, downloads and Ask about your book need a server. Books on this \(LocalDevice.noun) stay here either way.")
                }
                .listRowBackground(Palette.surface)

                Section {
                    LabeledContent("Version", value: Self.version)
                } header: {
                    Text("About")
                }
                .listRowBackground(Palette.surface)
            }
            .paperListBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                let root = library.root
                let uuids = library.books.map(\.uuid)
                spaceUsed = await Task.detached(priority: .utility) {
                    LocalLibrary.sizes(of: uuids, root: root).values.reduce(0, +)
                }.value
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Palette.paper)
        .accessibilityIdentifier("screen.localSettings")
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
#endif
