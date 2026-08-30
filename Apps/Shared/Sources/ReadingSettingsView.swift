import IssaPlayback
import IssaRender
import IssaUI
import SwiftUI

/// Typography, theme and read-along highlight controls, as the design lays out.
public struct ReadingSettingsView: View {
    @Environment(PlaybackSettings.self) private var settings

    public init() {}

    public var body: some View {
        @Bindable var settings = settings

        List {
            Section("Page theme") {
                Picker("Theme", selection: $settings.readerStyle.theme) {
                    ForEach(ReaderTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue.capitalized).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Palette.surface)

            Section("Type") {
                Picker("Typeface", selection: $settings.readerStyle.fontFamily) {
                    Text("Newsreader").tag("Newsreader")
                    Text("Public Sans").tag("Public Sans")
                }
                // fontSize is a CGFloat for TextKit; bridge rather than
                // widening ValueStepper's API to every float type.
                ValueStepper(
                    "Text size",
                    value: Binding(
                        get: { Double(settings.readerStyle.fontSize) },
                        set: { settings.readerStyle.fontSize = CGFloat($0) },
                    ),
                    in: 12 ... 32, format: { "\(Int($0))pt" },
                )
                Picker("Line spacing", selection: $settings.readerStyle.lineSpacing) {
                    ForEach(ReaderStyle.LineSpacing.allCases, id: \.self) { spacing in
                        Text(spacing.rawValue.capitalized).tag(spacing)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Justified", isOn: $settings.readerStyle.justified)
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
        }
        .paperListBackground()
        .navigationTitle("Reading")
    }
}
