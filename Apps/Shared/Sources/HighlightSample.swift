import IssaRender
import IssaUI
import SwiftUI

/// A few lines of a book, on the chosen paper, with one sentence marked.
///
/// Settings can otherwise only show the highlighter as a circle of ink, and a
/// circle at full strength answers none of the questions actually being asked:
/// how much of the page shows through, whether the words underneath stay
/// readable, whether it looks like a marker or like a stain. Three lines of
/// real prose answer all three.
///
/// It has to be the same shape the page draws, or the sample would be a
/// promise the reader gets to check against the book a minute later — so the
/// marked sentence is filled through `HighlightBlock`, exactly as `PageSurface`
/// fills it, rather than as a per-line background.
///
/// In `Apps/Shared` rather than beside `HighlighterPicker` in IssaUI, which is
/// where the rest of this control lives: `HighlightBlock` is IssaRender's, and
/// IssaRender already depends on IssaUI, so a sample in IssaUI would close the
/// cycle. Here both are in scope.
struct HighlightSample: View {
    private let theme: ReaderTheme
    private let highlight: Color
    private let fontFamily: String?

    init(theme: ReaderTheme, highlight: Color, fontFamily: String?) {
        self.theme = theme
        self.highlight = highlight
        self.fontFamily = fontFamily
    }

    /// From *Peter and Wendy*, which is the book the reader is most likely to
    /// have open — three sentences so the marked one has a line above and a
    /// line below, which is where the block's seams show.
    private static let opening = "Wendy knew that she must grow up. "
    private static let marked = "You always know after you are two."
    private static let closing = " Two is the beginning of the end."

    /// A reading size rather than a UI one. The sample is a picture of a page,
    /// and `HighlightBlock.Style(fontSize:)` derives the block's padding and
    /// corners from exactly this number.
    private static let size: CGFloat = 17

    var body: some View {
        Text("\(Text(Self.opening))\(Text(Self.marked).customAttribute(HighlightMark()))\(Text(Self.closing))")
            .font(.custom(fontFamily ?? ReaderStyle.defaultFamily, size: Self.size))
            .foregroundStyle(theme.text)
            .textRenderer(HighlightBlockRenderer(
                highlight: highlight,
                style: HighlightBlock.Style(fontSize: Self.size),
            ))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.spacing16)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusMedium).fill(theme.background),
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sample of the highlighter on \(theme.title)")
    }
}

// MARK: - Marking one sentence

/// Marks the run that the sample highlights.
///
/// A `TextAttribute` rather than an `AttributedString` background, because a
/// background is drawn per glyph run and would reproduce the very seam the
/// block exists to remove. This carries no value: its presence *is* the mark.
private struct HighlightMark: TextAttribute {}

/// Fills the marked runs as one block, then draws the type over it.
///
/// The renderer sees the text already laid out, so the marked runs' line
/// rectangles are the same input `PageSurface` gets from TextKit — which means
/// the sample and the page go through one path builder and cannot disagree.
private struct HighlightBlockRenderer: TextRenderer {
    let highlight: Color
    let style: HighlightBlock.Style

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        // Underneath the glyphs, in one fill, for the reason recorded on
        // `HighlightBlock`: two translucent fills that share an edge composite
        // to a darker band along it.
        let marked = layout.flatMap { line in
            line.filter { $0[HighlightMark.self] != nil }
                .map(\.typographicBounds.rect)
        }
        if !marked.isEmpty {
            context.fill(
                Path(HighlightBlock.path(lineRects: marked, style: style)),
                with: .color(highlight),
            )
        }
        for line in layout {
            for run in line { context.draw(run) }
        }
    }
}
