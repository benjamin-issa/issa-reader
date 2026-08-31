import IssaRender
import IssaUI
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// The typography controls, shared by the global settings and the per-book
/// sheet.
///
/// One view rather than two, so that "Aa" in the reader and "Reading &
/// highlights" in Settings cannot drift apart — they are the same choices, made
/// at different scopes.
struct TypographyControls: View {
    @Binding var style: ReaderStyle
    /// The face this book embeds, when there is a usable one.
    var publisherFamily: String?
    /// What to say about the book's own face when it cannot be used.
    var publisherNote: String?
    /// Imported faces, refreshed when one is added.
    var customFamilies: [String]
    var onImport: (() -> Void)?

    var body: some View {
        Picker("Typeface", selection: typefaceSelection) {
            if publisherFamily != nil {
                Text("Publisher's font").tag(ReaderStyle.Typeface.publisher)
            }
            Text("Newsreader").tag(ReaderStyle.Typeface.bundled("Newsreader"))
            Text("Public Sans").tag(ReaderStyle.Typeface.bundled("Public Sans"))
            ForEach(customFamilies, id: \.self) { family in
                Text(family).tag(ReaderStyle.Typeface.custom(family))
            }
        }

        if let publisherNote, publisherFamily == nil {
            Text(publisherNote)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }

        if let onImport {
            Button {
                onImport()
            } label: {
                Label("Add a font…", systemImage: "plus.circle")
            }
        }

        // fontSize is a CGFloat for TextKit; bridge rather than widening
        // ValueStepper's API to every float type.
        ValueStepper(
            "Text size",
            value: Binding(
                get: { Double(style.fontSize) },
                set: { style.fontSize = CGFloat($0) },
            ),
            in: 12 ... 32, format: { "\(Int($0))pt" },
        )

        Picker("Line spacing", selection: $style.lineSpacing) {
            ForEach(ReaderStyle.LineSpacing.allCases, id: \.self) { spacing in
                Text(spacing.rawValue.capitalized).tag(spacing)
            }
        }
        .pickerStyle(.segmented)

        Toggle("Justified", isOn: $style.justified)
    }

    /// Keeps a selection that is no longer offered from clearing the picker.
    ///
    /// A book set in the publisher's face, reopened on a book that has none,
    /// would otherwise show an empty picker and lose the setting on the next
    /// touch.
    private var typefaceSelection: Binding<ReaderStyle.Typeface> {
        Binding(
            get: {
                if case .publisher = style.typeface, publisherFamily == nil {
                    return .bundled(ReaderStyle.defaultFamily)
                }
                return style.typeface
            },
            set: { style.typeface = $0 },
        )
    }
}

/// The font file types CoreText can read, for the importer.
enum FontImport {
    #if canImport(UniformTypeIdentifiers)
    /// `.font` covers OTF, TTF and collections. WOFF is deliberately not
    /// offered: CoreText cannot read it, so importing one would appear to work
    /// and then render nothing.
    static var contentTypes: [UTType] {
        [UTType.font, UTType(filenameExtension: "otf"), UTType(filenameExtension: "ttf")]
            .compactMap { $0 }
    }
    #endif

    /// Copies a picked file into the app's font directory and registers it.
    ///
    /// Copied rather than referenced: the picked URL is a security-scoped
    /// loan from another app's container, and it is not there on the next
    /// launch — a face that vanished would leave the book set in a font the
    /// picker still listed.
    @discardableResult
    static func adopt(_ picked: URL) -> String? {
        guard let directory = CustomFonts.importedDirectory else { return nil }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let destination = directory.appendingPathComponent(picked.lastPathComponent)
        if !FileManager.default.fileExists(atPath: destination.path) {
            guard (try? FileManager.default.copyItem(at: picked, to: destination)) != nil
            else { return nil }
        }
        return CustomFonts.register(destination)
    }
}
