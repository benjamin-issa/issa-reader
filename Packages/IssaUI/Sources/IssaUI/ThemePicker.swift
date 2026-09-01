import SwiftUI

/// The page-colour control, as swatches.
///
/// One view rather than two, for the same reason `TypographyControls` is: it
/// appears both in Settings and in the reader's "Aa" sheet, and two copies of a
/// four-way picker drift.
///
/// Swatches rather than four words, because the choice is about how the page
/// will look and the answer can simply be shown. Each one is painted in its own
/// theme's colours — never `Palette` tokens — for the reason recorded on
/// `ReaderTheme` itself: the page's appearance is the reader's choice, so Paper
/// must look like paper even when the device is in Dark Mode.
public struct ThemePicker: View {
    @Binding private var selection: ReaderTheme

    public init(selection: Binding<ReaderTheme>) {
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: Metrics.spacing12) {
            ForEach(ReaderTheme.allCases, id: \.self) { theme in
                Button { selection = theme } label: { swatch(theme) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.title)
                    .accessibilityAddTraits(theme == selection ? [.isSelected] : [])
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spacing4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page colour")
    }

    private func swatch(_ theme: ReaderTheme) -> some View {
        VStack(spacing: Metrics.spacing8) {
            RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                .fill(theme.background)
                .frame(height: 52)
                .overlay {
                    // Two bars of "text" in the theme's own ink, so a swatch
                    // says what a page set in it will look like rather than
                    // only what colour the paper is.
                    VStack(alignment: .leading, spacing: 5) {
                        Capsule().fill(theme.text.opacity(0.75)).frame(height: 3)
                        Capsule().fill(theme.text.opacity(0.75)).frame(height: 3)
                        Capsule().fill(theme.text.opacity(0.75))
                            .frame(width: 18, height: 3)
                    }
                    .padding(.horizontal, 10)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.radiusSmall)
                        .strokeBorder(
                            theme == selection ? Palette.tangerine : Palette.border,
                            lineWidth: theme == selection ? 2 : 0.5,
                        )
                }

            Text(theme.title)
                .font(Typography.caption)
                .foregroundStyle(theme == selection ? Palette.ink : Palette.inkTertiary)
        }
    }
}
