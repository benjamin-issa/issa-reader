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
        // Grouped, because "which face is easiest for me to read" and "which
        // face do I like" are different questions, and the accessibility ones
        // are worth finding without reading the whole list.
        Picker("Typeface", selection: typefaceSelection) {
            Section {
                if publisherFamily != nil {
                    Text("Publisher's font").tag(ReaderStyle.Typeface.publisher)
                }
                ForEach(IssaFonts.readingFaces, id: \.family) { face in
                    Text(face.title).tag(ReaderStyle.Typeface.bundled(face.family))
                }
            } header: {
                Text("Reading")
            }

            Section {
                ForEach(IssaFonts.accessibilityFaces, id: \.family) { face in
                    Text(face.title).tag(ReaderStyle.Typeface.bundled(face.family))
                }
            } header: {
                Text("Accessibility")
            }

            if !customFamilies.isEmpty {
                Section {
                    ForEach(customFamilies, id: \.self) { family in
                        Text(family).tag(ReaderStyle.Typeface.custom(family))
                    }
                } header: {
                    Text("Your fonts")
                }
            }
        }

        if let publisherNote, publisherFamily == nil {
            Text(publisherNote)
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)
        }

        // Said rather than left to be discovered mid-chapter. Lexend ships no
        // italic at any weight, and `withItalicTrait` will not fake one.
        if case let .bundled(family) = style.typeface,
           let face = IssaFonts.allFaces.first(where: { $0.family == family }),
           !face.hasItalic {
            Text("\(face.title) has no italic, so emphasis is set upright.")
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
    /// A book set in the publisher's face, reopened on a book that has none —
    /// or set in an imported face whose file is no longer registered — would
    /// otherwise show an empty picker and lose the setting on the next touch.
    private var typefaceSelection: Binding<ReaderStyle.Typeface> {
        Binding(
            get: {
                if case .publisher = style.typeface, publisherFamily == nil {
                    return .bundled(ReaderStyle.defaultFamily)
                }
                if case let .custom(family) = style.typeface,
                   !customFamilies.contains(family) {
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
        let destination = destinationFor(picked, in: directory)
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        if !existedBefore {
            guard (try? FileManager.default.copyItem(at: picked, to: destination)) != nil
            else { return nil }
        }
        guard let family = CustomFonts.register(destination, imported: true) else {
            // A file CoreText rejects must not stay behind: `registerAll`
            // would retry it — and fail again — at every launch. Only the copy
            // this import just made is removed; a file that was already there
            // belongs to an earlier import.
            if !existedBefore { try? FileManager.default.removeItem(at: destination) }
            return nil
        }
        return family
    }

    /// Where the picked file should land, without trusting its name.
    ///
    /// Keying purely on the filename silently swapped fonts: a second,
    /// different file that happened to be called `Inter-Regular.ttf` was never
    /// copied, and the reader was switched to the face already on disk under
    /// that name. Identical bytes reuse the existing copy — re-importing the
    /// same font stays idempotent — and different bytes get a numbered name of
    /// their own.
    private static func destinationFor(_ picked: URL, in directory: URL) -> URL {
        let manager = FileManager.default
        let base = picked.deletingPathExtension().lastPathComponent
        let ext = picked.pathExtension
        var candidate = directory.appendingPathComponent(picked.lastPathComponent)
        var counter = 2
        while manager.fileExists(atPath: candidate.path),
              !manager.contentsEqual(atPath: picked.path, andPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
