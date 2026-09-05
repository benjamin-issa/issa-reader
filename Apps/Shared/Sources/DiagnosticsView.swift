import IssaCore
import IssaUI
import SwiftUI

/// Handing over what happened, when something goes wrong in a beta.
///
/// The log is the app's own file rather than `OSLogStore`, which can only see
/// the running process — and the launch worth reporting is usually the one
/// before the one you are looking at.
struct DiagnosticsView: View {
    @State private var exported: URL?
    @State private var preview: String = ""
    @State private var entryCount = 0
    @State private var confirmingClear = false

    var body: some View {
        List {
            Section {
                Text("Issa Reader keeps a record of what it did for the last six hours. If something goes wrong, export it and send it on.")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
            }
            .listRowBackground(Palette.surface)

            Section {
                LabeledContent("Entries", value: "\(entryCount)")
                LabeledContent("Covering", value: "Last 6 hours")
            } header: {
                Text("Recorded")
            }
            .listRowBackground(Palette.surface)

            Section {
                #if os(iOS) || os(macOS)
                if let exported {
                    ShareLink(item: exported) {
                        Label("Export logs", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Label("Export logs", systemImage: "square.and.arrow.up")
                        .foregroundStyle(Palette.inkQuaternary)
                }
                #endif
                Button {
                    Clipboard.copy(IssaLog.export())
                } label: {
                    Label("Copy to clipboard", systemImage: "doc.on.doc")
                }
            } footer: {
                // Said before anything is shared, not after: what the file
                // contains is the reader's decision to make.
                Text("The file names your server and the books you opened. Sign-in codes and access tokens are never recorded.")
                    .font(Typography.caption)
            }
            .listRowBackground(Palette.surface)

            Section {
                Text(preview.isEmpty ? "Nothing recorded yet." : preview)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Palette.inkSecondary)
                    #if !os(tvOS)
                    .textSelection(.enabled)
                    #endif
            } header: {
                Text("Most recent")
            }
            .listRowBackground(Palette.surface)

            Section {
                Button("Clear log", role: .destructive) { confirmingClear = true }
            }
            .listRowBackground(Palette.surface)
            .confirmationDialog(
                "Clear the log?", isPresented: $confirmingClear, titleVisibility: .visible,
            ) {
                Button("Clear", role: .destructive) {
                    IssaLog.clear()
                    reload()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .navigationTitle("Diagnostics")
        .paperListBackground()
        .task { reload() }
        .onDisappear { discardExport() }
    }

    /// Re-reads the log, and re-writes the export file.
    ///
    /// The file is prepared up front rather than on tap, because `ShareLink`
    /// wants an item to exist before the sheet opens — a link that builds its
    /// own file lazily shows an empty sheet the first time.
    private func reload() {
        entryCount = IssaLog.count()
        let text = IssaLog.export()
        // The tail, not the head: what just went wrong is at the end.
        preview = text.split(separator: "\n").suffix(12).joined(separator: "\n")
        exported = IssaLog.exportFile()
    }

    /// The export is a full copy of the log on disk. It exists because
    /// `ShareLink` needs its item to exist before the sheet opens, not because
    /// it should outlive the screen.
    private func discardExport() {
        exported = nil
        IssaLog.discardExports()
    }
}
