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
        #if os(macOS)
        // MacSettingsView places this screen straight into its TabView — no
        // navigation container anywhere above — so the "Fonts & licences"
        // link at the bottom drew as a row and did nothing when clicked,
        // leaving the licence screens unreachable on the one platform's only
        // route to them. The stack is brought along here rather than added
        // there because iOS pushes this same screen inside the Settings tab's
        // own stack, where a second stack must not nest.
        NavigationStack { content }
        #else
        content
        #endif
    }

    private var content: some View {
        @Bindable var settings = settings
        let theme = settings.readerStyle.theme

        return List {
            Section {
                caption("Page colour — \(theme.title)")
                ThemePicker(selection: $settings.readerStyle.theme)

                caption("Highlighter on \(theme.title)")
                HighlighterPicker(theme: theme, selection: highlighter(for: theme))
                HighlightSample(
                    theme: theme,
                    highlight: settings.readerStyle.highlightColor,
                    fontFamily: settings.readerStyle.resolvedFamily,
                )

                // Only once this page colour has departed from its default, so
                // the row is an answer to "how do I undo this" rather than a
                // permanent piece of furniture offering to undo nothing.
                if settings.readerStyle.highlighters[theme] != nil {
                    Button("Use default for \(theme.title)") {
                        settings.readerStyle.highlighters[theme] = nil
                    }
                }
            } header: {
                Text("Highlighter")
            } footer: {
                Text("The same control is in the reader under Aa. Page colour is one setting for every book, not a per-book choice like the type. Each page colour remembers its own highlighter for the sentence being read aloud.")
                    .settingsFooter()
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
                    .settingsFooter()
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
                    .settingsFooter()
            }
            .listRowBackground(Palette.surface)

            #if os(macOS)
            // The Mac's Settings window has no Ask row of its own — this screen
            // *is* its Reading tab, and there is no phone-style Settings list
            // above it to carry the section. On iOS it lives in `SettingsView`
            // only, so it is not offered twice.
            AskSettingsSection()
            #endif

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

    /// A quiet line naming what the control under it applies to.
    ///
    /// Both swatch rows are wordless, and stacked in one section they read as
    /// eight anonymous circles. Naming the page colour in each also states the
    /// thing the section is really about: the second row belongs to whichever
    /// paper the first row has chosen.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Typography.subhead)
            .foregroundStyle(Palette.inkSecondary)
    }

    /// A binding into one page colour's entry.
    ///
    /// Written out because `Binding` forwards member lookups, not subscripts,
    /// so `$settings.readerStyle.highlighters[theme]` does not compile.
    /// Assigning `nil` removes the key rather than storing an empty value,
    /// which is what keeps "this page colour has been changed" answerable as a
    /// presence test.
    private func highlighter(for theme: ReaderTheme) -> Binding<HighlighterChoice?> {
        Binding(
            get: { settings.readerStyle.highlighters[theme] },
            set: { settings.readerStyle.highlighters[theme] = $0 },
        )
    }
}
