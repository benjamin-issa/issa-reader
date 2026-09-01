import IssaPlayback
import IssaRender
import IssaUI
import SwiftUI

/// Typography, theme and read-along highlight controls, as the design lays out.
public struct ReadingSettingsView: View {
    @Environment(PlaybackSettings.self) private var settings

    @State private var customFamilies: [String] = []
    @State private var importing = false

    public init() {}

    public var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                ThemePicker(selection: $settings.readerStyle.theme)
            } header: {
                Text("Page colour")
            } footer: {
                Text("The same control is in the reader under Aa. Page colour is one setting for every book, not a per-book choice like the type.")
            }
            .listRowBackground(Palette.surface)

            Section {
                // The publisher's font is a per-book choice — there is no book
                // here — so this picker offers the app's faces and any the
                // reader imported.
                TypographyControls(
                    style: $settings.readerStyle,
                    publisherFamily: nil,
                    publisherNote: nil,
                    customFamilies: customFamilies,
                    onImport: { importing = true },
                )
            } header: {
                Text("Type")
            } footer: {
                Text("These are your defaults. Any book can depart from them — open it and tap Aa.")
            }
            .listRowBackground(Palette.surface)

            Section {
                Picker("Highlight", selection: $settings.readerStyle.highlightGranularity) {
                    ForEach(ReaderStyle.HighlightGranularity.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Follow narration", isOn: $settings.readerStyle.followNarration)
                Toggle("Turn pages mid-sentence", isOn: $settings.readerStyle.turnPagesMidSentence)
                Toggle("Double-tap a sentence to play it", isOn: $settings.readerStyle.tapToPlay)
                Picker("Progress shows", selection: $settings.readerStyle.progressDisplay) {
                    ForEach(ReaderStyle.ProgressDisplay.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
            } header: {
                Text("Read-along")
            } footer: {
                Text("“Follow narration” keeps the spoken sentence on screen. Turning pages mid-sentence flips as soon as the text runs off, rather than waiting for the sentence to finish. Double-tapping a sentence starts the narration there.")
            }
            .listRowBackground(Palette.surface)

            Section {
                NavigationLink { FontLicencesView() } label: {
                    Label("Fonts & licences", systemImage: "textformat.alt")
                }
            }
            .listRowBackground(Palette.surface)
        }
        .paperListBackground()
        .navigationTitle("Reading")
        .task { customFamilies = CustomFonts.families() }
        #if os(iOS) || os(macOS)
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: FontImport.contentTypes,
            allowsMultipleSelection: false,
        ) { result in
            guard case let .success(urls) = result, let picked = urls.first else { return }
            if let family = FontImport.adopt(picked) {
                customFamilies = CustomFonts.families()
                // Selected straight away: importing a font and then having to
                // find it in a list is a step with no purpose.
                settings.readerStyle.typeface = .custom(family)
            }
        }
        #endif
    }
}
