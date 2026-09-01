import IssaRender
import IssaUI
import SwiftUI

/// Who made the faces the app ships, and under what terms.
///
/// The SIL Open Font License asks that it travel with the font software. Each
/// family's own licence file sits beside the files in the resource bundle; this
/// is where a reader can actually read one.
struct FontLicencesView: View {
    var body: some View {
        List {
            Section {
                ForEach(IssaFonts.allFaces, id: \.family) { face in
                    NavigationLink {
                        LicenceText(face: face)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(face.title)
                                .font(Typography.body)
                                .foregroundStyle(Palette.ink)
                            Text(copyrightLine(for: face) ?? "SIL Open Font License 1.1")
                                .font(Typography.caption)
                                .foregroundStyle(Palette.inkTertiary)
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                Text("Bundled faces")
            } footer: {
                Text("Every face the app ships is under the SIL Open Font License 1.1. Fonts you import yourself are governed by their own terms.")
            }
            .listRowBackground(Palette.surface)
        }
        .paperListBackground()
        .navigationTitle("Fonts & licences")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The first line of the licence, which is the copyright statement in every
    /// OFL file. Read from the file rather than restated here, so the two
    /// cannot disagree.
    private func copyrightLine(for face: BundledFace) -> String? {
        IssaFonts.licence(for: face.family)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }
}

private struct LicenceText: View {
    let face: BundledFace

    var body: some View {
        ScrollView {
            Text(IssaFonts.licence(for: face.family) ?? "Licence text unavailable.")
                .font(Typography.caption.monospaced())
                .foregroundStyle(Palette.inkSecondary)
                // Selectable where a pointer or a finger can select, which the
                // TV has neither of.
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Metrics.spacing16)
        }
        .background(Palette.paper)
        .navigationTitle(face.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
