import SwiftUI

/// The highlighter control for one page colour, as swatches.
///
/// Beside `ThemePicker` and built the same way, because it answers the second
/// half of the same question: that one picks the paper, this one picks the pen.
/// Only the four swatches that suit the ground in force are offered — the
/// light-page pigments would vanish into a near-black page and the lifted
/// dark-page ones look chalky on cream — so the picker takes the theme rather
/// than reading it, and Settings redraws it when the paper changes.
public struct HighlighterPicker: View {
    private let theme: ReaderTheme
    @Binding private var selection: HighlighterChoice?

    #if os(iOS) || os(macOS)
    /// The whole environment, because `Color.resolve(in:)` needs it to turn
    /// whatever the system picker hands back into four fixed numbers. A
    /// custom colour is stored resolved for the same reason the reading themes
    /// are literal: it must not change because the device went dark overnight.
    @Environment(\.self) private var environment
    #endif

    /// Diameter of a swatch, the ring's weight, and the clear space between
    /// the two. The gap is the point of the design: a tangerine ring drawn
    /// straight onto a tangerine swatch is invisible, so the selected state
    /// has to sit *off* the colour it marks.
    private static let diameter: CGFloat = 36
    private static let ringWidth: CGFloat = 2
    private static let ringGap: CGFloat = 3

    public init(theme: ReaderTheme, selection: Binding<HighlighterChoice?>) {
        self.theme = theme
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: Metrics.spacing12) {
            ForEach(theme.highlighterPresets, id: \.self) { preset in
                Button { choose(preset) } label: {
                    ringed(isSelected(preset)) { Circle().fill(Color(hex: preset.hex)) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityAddTraits(isSelected(preset) ? [.isSelected] : [])
            }
            #if os(iOS) || os(macOS)
            customSwatch
            #endif
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.spacing4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Highlighter")
    }

    // MARK: - The swatches

    /// A swatch is drawn at full strength, not at the alpha the page paints it
    /// at. Four washes of 22 % on a white list row are four barely different
    /// greys; the pigment is what tells them apart.
    private func ringed(_ selected: Bool, @ViewBuilder content: () -> some View) -> some View {
        content()
            .frame(width: Self.diameter, height: Self.diameter)
            .overlay {
                Circle()
                    .strokeBorder(Palette.ink, lineWidth: Self.ringWidth)
                    // Grown outwards by the gap plus the whole stroke, since
                    // `strokeBorder` then insets by half of it — which leaves
                    // exactly `ringGap` of clear paper around the swatch.
                    .padding(-(Self.ringGap + Self.ringWidth))
                    .opacity(selected ? 1 : 0)
            }
            // Room for the ring, so the row is the same height whether or not
            // anything in it is selected.
            .padding(Self.ringGap + Self.ringWidth)
    }

    #if os(iOS) || os(macOS)
    /// The fifth swatch: the system colour picker, wearing the same ring.
    ///
    /// Label-less, because the four beside it have no labels either and a
    /// "Custom colour" caption in the middle of a row of circles reads as a
    /// misplaced form field. VoiceOver still gets the name.
    private var customSwatch: some View {
        ringed(isCustom) {
            ColorPicker(selection: customBinding, supportsOpacity: true) { EmptyView() }
                .labelsHidden()
        }
        .accessibilityLabel("Custom colour")
        .accessibilityAddTraits(isCustom ? [.isSelected] : [])
    }

    /// What the system picker opens on, and what it writes back.
    ///
    /// It opens on the colour the page is actually using — including a preset,
    /// so "nearly that, but greener" starts from the right place rather than
    /// from black.
    private var customBinding: Binding<Color> {
        Binding(
            get: {
                if case let .custom(tint) = selection { return tint.color }
                return theme.highlightColor(for: selection)
            },
            set: { selection = .custom(HighlightTint($0.resolve(in: environment))) },
        )
    }
    #endif

    // MARK: - Choosing

    /// Picking the ground's own default stores *nothing*.
    ///
    /// Normalising here is what makes "this page colour has been changed"
    /// answerable as `selection != nil` everywhere else — the "Use default"
    /// button, the settings blob, the page. Storing `.preset(.tangerine)` for
    /// Paper would be a departure that looks identical and behaves as one.
    private func choose(_ preset: HighlighterPreset) {
        selection = preset == theme.defaultHighlighter ? nil : .preset(preset)
    }

    private func isSelected(_ preset: HighlighterPreset) -> Bool {
        (selection ?? .preset(theme.defaultHighlighter)) == .preset(preset)
    }

    private var isCustom: Bool {
        if case .custom = selection { return true }
        return false
    }
}
