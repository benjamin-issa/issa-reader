import IssaCore
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

            if !listedCustomFamilies.isEmpty {
                Section {
                    ForEach(listedCustomFamilies, id: \.self) { family in
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
                FontImport.notice.clear()
                onImport()
            } label: {
                Label("Add a font…", systemImage: "plus.circle")
            }
            // Said, because the picker closing with nothing changed looked
            // exactly like an import that worked and had not refreshed.
            if let failure = FontImport.notice.message {
                Text(failure)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.alert)
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

        // Three positions rather than two, because a book has an opinion here
        // and a switch could not say whose wins. "Follow the book" is the
        // default and does what the publisher set; the other two are the
        // reader overruling it either way.
        //
        // A row with the choice on the right, like "Progress bar" in Settings,
        // rather than the segmented control the line spacing above uses:
        // "Follow the book" is a phrase, and three of those do not fit across a
        // 375pt screen without one of them becoming "Follow the…".
        Picker("Justify text", selection: $style.justification) {
            ForEach(ReaderStyle.Justification.allCases, id: \.self) { justification in
                Text(justification.title).tag(justification)
            }
        }
    }

    /// The imported faces worth listing under "Your fonts".
    private var listedCustomFamilies: [String] {
        Self.listedCustomFamilies(customFamilies)
    }

    /// Imported faces less any family the app ships.
    ///
    /// A copy of Literata imported by the reader registers as Literata — the
    /// app's own — and listing it again under "Your fonts" offered one face
    /// twice, the second time as though it were the reader's file.
    static func listedCustomFamilies(_ families: [String]) -> [String] {
        families.filter { CustomFonts.bundledFamily(matching: $0) == nil }
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
                if case let .custom(family) = style.typeface {
                    // A bundled family chosen as an import is the bundled row.
                    if let bundled = CustomFonts.bundledFamily(matching: family) {
                        return .bundled(bundled)
                    }
                    if !listedCustomFamilies.contains(family) {
                        return .bundled(ReaderStyle.defaultFamily)
                    }
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
    ///
    /// A failure is said, in `notice`, and logged. It used to be neither: the
    /// picker closed, "Your fonts" was unchanged, and nothing anywhere told a
    /// damaged or unreadable file from an import that had quietly worked.
    @MainActor
    @discardableResult
    static func adopt(_ picked: URL) -> String? {
        notice.clear()
        guard let directory = CustomFonts.importedDirectory else {
            return refuse(picked, "That font couldn't be saved on this device.", reason: "no font directory")
        }
        let scoped = picked.startAccessingSecurityScopedResource()
        defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
        let destination = destinationFor(picked, in: directory)
        let existedBefore = FileManager.default.fileExists(atPath: destination.path)
        if !existedBefore {
            guard (try? FileManager.default.copyItem(at: picked, to: destination)) != nil
            else { return refuse(picked, "That file couldn't be opened.", reason: "copy failed") }
        }
        guard let family = CustomFonts.register(destination, imported: true) else {
            // A file CoreText rejects must not stay behind: `registerAll`
            // would retry it — and fail again — at every launch. Only the copy
            // this import just made is removed; a file that was already there
            // belongs to an earlier import.
            if !existedBefore { try? FileManager.default.removeItem(at: destination) }
            return refuse(picked, unreadableSentence(for: picked), reason: "not a readable font")
        }
        // A copy of a family the app ships is answered with the app's own,
        // and `register` never registers it — so the copy did nothing but sit
        // in the fonts folder, never listed under "Your fonts" and so with no
        // way to remove it (F9). It goes now; the bundled row is chosen.
        // Unregistering first is not needed: it was never registered.
        if CustomFonts.bundledFamily(matching: family) != nil {
            try? FileManager.default.removeItem(at: destination)
        }
        return family
    }

    /// The typeface to choose for a family an import answered with: the
    /// app's own row when the file was a copy of a family it ships.
    static func typeface(for family: String) -> ReaderStyle.Typeface {
        CustomFonts.bundledFamily(matching: family).map { .bundled($0) } ?? .custom(family)
    }

    /// What to say about a file CoreText would not take.
    static func unreadableSentence(for picked: URL) -> String {
        switch picked.pathExtension.lowercased() {
        case "woff", "woff2":
            "WOFF fonts can't be used on this device. Try the OTF or TTF version of the font."
        default:
            "That file isn't a font this device can read."
        }
    }

    @MainActor
    private static func refuse(_ picked: URL, _ sentence: String, reason: String) -> String? {
        IssaLog.warning("font import refused", [
            "reason": reason,
            "extension": picked.pathExtension.lowercased(),
        ])
        notice.message = sentence
        return nil
    }

    /// What the last import could not do, for the controls to say under
    /// "Add a font…". One for the app, because the two screens that import —
    /// Settings and a book's own sheet — share the controls that say it.
    @MainActor static let notice = Notice()

    @Observable
    @MainActor
    final class Notice {
        fileprivate(set) var message: String?

        func clear() { message = nil }
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
