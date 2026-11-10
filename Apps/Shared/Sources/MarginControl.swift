import IssaRender
import IssaUI
import SwiftUI

/// The four named margins the control offers beside its slider.
///
/// Standard is the real default (`ReaderStyle().pageMargin`), not a round
/// number picked for the picture.
enum MarginPreset: CaseIterable, Identifiable {
    case wide, standard, narrow, edge

    var id: Self { self }

    var points: CGFloat {
        switch self {
        case .wide: 48
        case .standard: 24
        case .narrow: 12
        case .edge: 4
        }
    }

    var title: String {
        switch self {
        case .wide: "Wide"
        case .standard: "Standard"
        case .narrow: "Narrow"
        case .edge: "Edge"
        }
    }

    var identifier: String { "typography.margins.\(title.lowercased())" }
}

/// What the margin control decides, apart from how it draws it.
enum MarginControlModel {
    /// What the slider can set. The stored range is wider (up to 200), which a
    /// reader on a phone has no use for and the slider would make unusable.
    static let sliderRange: ClosedRange<Double> = 0 ... 64
    static let step: Double = 2

    /// Where the slider's thumb stands for a stored margin: clamped to the
    /// track, never written back.
    static func sliderValue(for stored: CGFloat) -> Double {
        min(max(Double(stored), sliderRange.lowerBound), sliderRange.upperBound)
    }

    /// The label's number: the margin as stored, even past the track's end.
    static func displayedPoints(for stored: CGFloat) -> Int {
        Int(stored.rounded())
    }

    /// The preset standing for this margin, when one does.
    static func preset(for stored: CGFloat) -> MarginPreset? {
        MarginPreset.allCases.first { abs($0.points - stored) < 0.5 }
    }
}

/// Whether the reader should draw the margins as bands, because the margin is
/// being adjusted.
///
/// One instance per reader, handed to the Aa sheet's controls. Bands show while
/// the slider is held, and for a moment after anything moves it — a preset tap
/// has no "being dragged" to hold them up, and the reader has to see where the
/// edge landed.
@Observable
@MainActor
final class MarginPreview {
    private(set) var isDragging = false
    private(set) var isLingering = false

    var isShowing: Bool { isDragging || isLingering }

    @ObservationIgnored private var lingerTask: Task<Void, Never>?
    @ObservationIgnored private let lingerFor: Duration

    init(lingerFor: Duration = .milliseconds(1500)) {
        self.lingerFor = lingerFor
    }

    /// The slider was grabbed or let go. Letting go keeps the bands up a
    /// little longer.
    func dragging(_ on: Bool) {
        isDragging = on
        if !on { linger() }
    }

    /// Show the bands now and for `lingerFor` after the last call.
    func linger() {
        lingerTask?.cancel()
        isLingering = true
        let delay = lingerFor
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.isLingering = false
        }
    }

    /// Nothing is being adjusted any more: the sheet closed.
    func reset() {
        lingerTask?.cancel()
        lingerTask = nil
        isDragging = false
        isLingering = false
    }
}

#if !os(tvOS)
/// The "Margins" row of the typography controls: a slider, four presets and a
/// line saying what it covers.
///
/// Shared by Settings (the default for every book) and a book's own Aa sheet
/// (this book's), like the rest of `TypographyControls`.
struct MarginControl: View {
    @Binding var style: ReaderStyle
    var preview: MarginPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing12) {
            HStack {
                Text("Margins").foregroundStyle(Palette.ink)
                Spacer()
                Text("\(MarginControlModel.displayedPoints(for: style.pageMargin)) pt")
                    .font(Typography.body.monospacedDigit())
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityIdentifier("typography.margins.value")
            }
            // The slider carries the name and the number for VoiceOver.
            .accessibilityHidden(true)

            HStack(spacing: Metrics.spacing12) {
                Image(systemName: "rectangle.portrait.fill")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
                Slider(
                    value: sliderBinding,
                    in: MarginControlModel.sliderRange,
                    step: MarginControlModel.step,
                    onEditingChanged: { preview?.dragging($0) },
                )
                .tint(Palette.tangerine)
                .accessibilityLabel("Margins")
                .accessibilityValue("\(MarginControlModel.displayedPoints(for: style.pageMargin)) points")
                .accessibilityIdentifier("typography.margins")
                Image(systemName: "rectangle.portrait.center.inset.filled")
                    .font(Typography.footnote)
                    .foregroundStyle(Palette.inkSecondary)
                    .accessibilityHidden(true)
            }

            HStack(spacing: Metrics.spacing8) {
                ForEach(MarginPreset.allCases) { preset in
                    presetButton(preset)
                }
            }

            Text("Applies in portrait and landscape.")
                .font(Typography.caption)
                .foregroundStyle(Palette.inkSecondary)
        }
        .padding(.vertical, Metrics.spacing4)
    }

    /// A stored value past the track shows at its end and stays as stored:
    /// only a move of the thumb writes anything.
    private var sliderBinding: Binding<Double> {
        Binding(
            get: { MarginControlModel.sliderValue(for: style.pageMargin) },
            set: { moved in
                guard moved != MarginControlModel.sliderValue(for: style.pageMargin) else { return }
                style.pageMargin = CGFloat(moved)
                preview?.linger()
            },
        )
    }

    private func presetButton(_ preset: MarginPreset) -> some View {
        let selected = MarginControlModel.preset(for: style.pageMargin) == preset
        return Button {
            style.pageMargin = preset.points
            preview?.linger()
        } label: {
            Text(preset.title)
                .font(Typography.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, minHeight: 36)
                // Dark ink on the tangerine in both appearances: the light
                // palette's ink is cream in Dark Mode, which is under 2:1 on
                // the lighter tangerine. `paper.text` is the fixed dark ink,
                // about 6:1 on either tangerine.
                .foregroundStyle(selected ? ReaderTheme.paper.text : Palette.ink)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .fill(selected ? Palette.tangerine : Palette.surfaceRaised),
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                        .strokeBorder(selected ? Palette.tangerine : Palette.border, lineWidth: 1),
                )
                .contentShape(RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        }
        // Plain: inside a list row, any other style makes the whole row one
        // button, and all four presets fire together.
        .buttonStyle(.plain)
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(preset.identifier)
    }
}

/// The two bands the reader draws over the page's margins while they are being
/// adjusted: a tangerine tint, with a dashed line along the edge the text
/// keeps to.
struct MarginBands: View {
    /// Each band's extent along the width, in this view's coordinates, left
    /// then right.
    let bands: [ClosedRange<CGFloat>]

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                let width = max(band.upperBound - band.lowerBound, 0)
                let isLeft = index.isMultiple(of: 2)
                Rectangle()
                    .fill(Palette.tangerine.opacity(0.14))
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .overlay(alignment: isLeft ? .trailing : .leading) {
                        // The text edge, on the inside of each band.
                        Rectangle()
                            .stroke(
                                Palette.tangerine,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: 1)
                            .frame(maxHeight: .infinity)
                    }
                    .offset(x: band.lowerBound)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The bands for one page: the margin at each side of a track `width` wide.
    static func page(width: CGFloat, margin: CGFloat) -> [ClosedRange<CGFloat>] {
        let m = min(max(margin, 0), width / 2)
        return [0 ... m, (width - m) ... width]
    }

    /// The bands for a spread: the margin outside each page's text box, at
    /// the spread's real text edges. Bands are in the spread view's
    /// coordinates (`leftX`, `rightX` are where the text boxes begin).
    static func spread(leftX: CGFloat, rightX: CGFloat, pageWidth: CGFloat, margin: CGFloat) -> [ClosedRange<CGFloat>] {
        let m = max(margin, 0)
        return [(leftX - m) ... leftX, (rightX + pageWidth) ... (rightX + pageWidth + m)]
    }
}
#endif
