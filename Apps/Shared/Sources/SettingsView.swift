import IssaCore
import IssaUI
import SwiftUI

public struct SettingsView: View {
    @Environment(AppModel.self) private var app

    public init() {}

    public var body: some View {
        List {
            if let session = app.session, case let .signedIn(user) = session.state {
                Section("Account") {
                    LabeledContent("Signed in as", value: user.username ?? user.name ?? "—")
                    LabeledContent("Server", value: session.serverURL.absoluteString)
                }

                Section {
                    LabeledContent("Books", value: "\(app.books.count)")
                    LabeledContent("With narration", value: "\(app.derivation.readalongs.count)")
                } header: {
                    Text("Library")
                }

                // Surfacing this makes it obvious which server generation is in
                // play, and why some rails are computed locally.
                Section {
                    capabilityRow("Home sections", session.capabilities.homeSections)
                    capabilityRow("Shelves", session.capabilities.shelves)
                    capabilityRow("Library facets", session.capabilities.libraryFacets)
                    capabilityRow("Server discovery", session.capabilities.serverDiscovery)
                } header: {
                    Text("Server capabilities")
                } footer: {
                    Text("Features your server does not provide are computed on this device instead.")
                }
            }

            Section {
                Button("Sign out", role: .destructive) {
                    Task { await app.signOut() }
                }
            }
        }
    }

    private func capabilityRow(_ name: String, _ available: Bool) -> some View {
        LabeledContent(name) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Palette.moss : Palette.inkQuaternary)
        }
    }
}
