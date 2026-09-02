import IssaCore
import IssaRender
import IssaUI
import SwiftUI

/// One book's own typography, reached from "Aa" in the reader.
///
/// Edits are stored as a *departure* from the reading settings rather than as a
/// whole style, so a book that only changes its face still follows a later
/// change to the global line spacing. "Use my defaults" removes the departure
/// entirely rather than copying today's defaults into it.
struct BookTypographyView: View {
    let book: Book
    /// The face this book embeds, when it has a usable one.
    let publisherFamily: String?
    let publisherNote: String
    /// Applies the resolved style to the open reader.
    let onChange: () -> Void

    @Environment(PlaybackSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var style = ReaderStyle()
    @State private var customFamilies: [String] = []
    @State private var importing = false
    /// Set once the sheet has seeded `style`, so nothing that fires before the
    /// load can be mistaken for an edit. The seed itself is told apart in
    /// `onChange` instead — see there for why this flag cannot catch it.
    @State private var loaded = false

    var body: some View {
        @Bindable var settings = settings

        return NavigationStack {
            List {
                // Bound to the global value, not to this sheet's `style`.
                // `ReaderStyleOverride` carries typeface, size, spacing and
                // justification and nothing else, so a theme written through
                // `style` would be dropped on the floor by `difference(to:)` —
                // it would appear to work and then not persist.
                Section {
                    ThemePicker(selection: $settings.readerStyle.theme)
                } header: {
                    Text("Page colour")
                } footer: {
                    Text("Applies to every book, unlike the settings below.")
                }
                .listRowBackground(Palette.surface)

                Section {
                    TypographyControls(
                        style: $style,
                        publisherFamily: publisherFamily,
                        publisherNote: publisherNote,
                        customFamilies: customFamilies,
                        onImport: { importing = true },
                    )
                } header: {
                    Text("This book")
                } footer: {
                    Text(footer)
                }
                .listRowBackground(Palette.surface)

                if let override = settings.override(for: book.uuid), !override.isEmpty {
                    Section {
                        Button("Use my defaults", role: .destructive) {
                            settings.setOverride(nil, for: book.uuid)
                            style = settings.readerStyle
                            onChange()
                        }
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .navigationTitle(Text(book.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .paperListBackground()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            customFamilies = CustomFonts.families()
            style = settings.style(for: book.uuid)
            loaded = true
        }
        .onChange(of: style) { _, edited in
            guard loaded else { return }
            // `loaded` cannot tell the seed from an edit: `.task` assigns
            // `style` and the flag in one main-actor block, and SwiftUI
            // delivers that first change afterwards, when the flag already
            // reads true. What does mark the seed is that writing it back
            // would change nothing — it *is* the stored style — so any value
            // that still matches is skipped. Without this, merely opening the
            // sheet re-derived the override, and once the global settings had
            // caught up with a book's own choice, `difference(to:)` came back
            // empty and deleted that choice outright.
            guard edited != settings.style(for: book.uuid) else { return }
            settings.setOverride(settings.readerStyle.difference(to: edited), for: book.uuid)
            onChange()
        }
        #if os(iOS) || os(macOS)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: FontImport.contentTypes,
            allowsMultipleSelection: false,
        ) { result in
            guard case let .success(urls) = result, let picked = urls.first else { return }
            if let family = FontImport.adopt(picked) {
                customFamilies = CustomFonts.families()
                style.typeface = .custom(family)
            }
        }
        #endif
    }

    private var footer: String {
        let override = settings.override(for: book.uuid)
        guard let override, !override.isEmpty else {
            return "This book follows your reading settings. Change anything here and it keeps its own."
        }
        return override.count == 1
            ? "This book keeps 1 setting of its own."
            : "This book keeps \(override.count) settings of its own."
    }
}
