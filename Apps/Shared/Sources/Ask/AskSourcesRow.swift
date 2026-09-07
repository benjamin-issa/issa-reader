#if !os(tvOS)
import IssaAsk
import IssaUI
import SwiftUI

/// The excerpts an answer rests on, under the answer.
///
/// The trust affordance the feature has been missing: until this shipped,
/// nothing under `Apps/` read `AskAnswer.citations` at all — the model was
/// instructed to cite, the prompt numbered its excerpts so that citations could
/// be told apart, the parser stripped the `Sources:` line, and the whole
/// apparatus ended in a property nobody looked at.
///
/// **Three chips, one open at a time, and the card opens in place.** Not a
/// `DisclosureGroup`: its chevron sits left of a label and reads as an outline
/// row under prose, which on the Mac is a control from a different screen. Not a
/// scroll view: this lives inside a sheet detent, and a horizontal scroller
/// inside one is a gesture fight the reader loses in both directions.
///
/// **Inside the measured stack, unlike `AskOriginPill`.** The pill is a standing
/// caption that must never move the detent, so it sits outside the `VStack`
/// `AskSheet` measures. Sources are part of the answer: when a reader opens one,
/// the height it adds is height the sheet should grow to fit, and the existing
/// `onContentHeight` → `askDetent` path does exactly that for nothing. Closed,
/// the row costs roughly fifty points — an 11pt overline, one `spacing8`, and a
/// 12pt chip inside two `spacing8` paddings — which keeps a short answer under
/// the 300pt threshold and so on the medium detent, where the page the question
/// is about stays visible behind it.
struct AskSourcesRow: View {
    let sources: [AskSource]
    /// The chapter each excerpt is in, resolved by the caller: only
    /// `ReaderModel` can name a chapter, and only for a book it has open.
    let title: (AskSource) -> String?
    let onOpen: (AskSource) -> Void

    /// Which chip is open, by ordinal. One at a time: two cards stacked under an
    /// answer is the answer scrolled off the top of a half sheet.
    @State private var opened: Int?

    /// Three. A fourth chip wraps to a second row on a phone, and by the fourth
    /// excerpt the model is citing everything it was handed rather than what it
    /// used.
    static let limit = 3

    private var shown: [AskSource] { Array(sources.prefix(Self.limit)) }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Sources").overlineStyle()

                HStack(spacing: Metrics.spacing8) {
                    ForEach(shown) { source in
                        chip(source)
                    }
                }

                if let opened, let source = shown.first(where: { $0.ordinal == opened }) {
                    card(source)
                }
            }
            .accessibilityIdentifier("ask.sources")
        }
    }

    // MARK: - Pieces

    /// The suggestion chip's own recipe, so the two rows in this sheet are one
    /// idea rather than two capsule styles that drifted apart.
    private func chip(_ source: AskSource) -> some View {
        let isOpen = opened == source.ordinal
        return Button {
            opened = isOpen ? nil : source.ordinal
        } label: {
            Text(AskSourceLabel.chip(source))
                .font(Typography.footnote)
                .foregroundStyle(isOpen ? Palette.ink : Palette.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, Metrics.spacing12)
                .padding(.vertical, Metrics.spacing8)
                .background(isOpen ? Palette.surfaceRaised : Palette.surface, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(
                        isOpen ? Palette.borderStrong : Palette.border, lineWidth: 1,
                    ),
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Source \(source.ordinal)")
        .accessibilityHint(isOpen ? "Hides the excerpt" : "Shows the excerpt")
    }

    private func card(_ source: AskSource) -> some View {
        VStack(alignment: .leading, spacing: Metrics.spacing8) {
            Text(AskSourceLabel.heading(source, title: title(source)))
                .font(Typography.caption)
                .foregroundStyle(Palette.inkTertiary)

            // Six lines: enough for the paragraph to be recognisable, and short
            // of a long passage pushing the answer itself off a medium detent.
            Text(source.passage.displayText)
                .font(Typography.subhead)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                onOpen(source)
            } label: {
                HStack(spacing: Metrics.spacing4) {
                    Text("Open in the book")
                    Image(systemName: "arrow.right")
                }
                .font(Typography.footnote.weight(.semibold))
                .foregroundStyle(Palette.tangerine)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ask.source.open")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.spacing12)
        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: Metrics.radiusMedium))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.radiusMedium)
                .strokeBorder(Palette.border, lineWidth: 1)
        }
    }
}

// MARK: -

/// The two strings the sources row shows, lifted out of the view.
///
/// `IssaSharedTests` is an iOS test bundle that cannot reach a SwiftUI `View`,
/// which is the same reason `TVPageMetrics`, `TVReaderStyle` and
/// `ReadingBoundary` are plain types beside their views rather than inside them.
/// The two decisions here — where to cut a chip's text, and what to call a
/// chapter the book never named — are both worth pinning.
enum AskSourceLabel {
    /// The first few words of the excerpt, in quotation marks, on one line.
    ///
    /// Cut at a word boundary rather than mid-word: three chips of ellipsised
    /// text is already a lot of punctuation, and "…a White Rab…" reads as a
    /// rendering fault rather than as a quotation. Whitespace is collapsed first
    /// because a passage keeps the newlines the chapter's tiling gave it, and a
    /// chip is one line.
    static func chip(_ source: AskSource, limit: Int = 32) -> String {
        let text = source.passage.displayText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !text.isEmpty else { return "\(source.ordinal)" }
        guard text.count > limit else { return "“\(text)”" }

        let clipped = text.prefix(limit)
        let cut = clipped.lastIndex(of: " ").map { String(clipped[..<$0]) } ?? String(clipped)
        return "“\(cut.isEmpty ? String(clipped) : cut)…”"
    }

    /// What the card calls the place the excerpt came from.
    ///
    /// The chapter's own name when the book has one — `ReaderModel` resolves it
    /// through `title(inSpineItem:atOffset:)`, which handles Gutenberg's
    /// one-file-many-chapters shape. Failing that, the section number the model
    /// itself was shown (`[1] (Section 3) …`), because a card headed "Chapter 3"
    /// for a spine item that is a preface is a worse answer than one that admits
    /// it is counting files.
    static func heading(_ source: AskSource, title: String?) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return title
        }
        return "Section \(source.passage.spineIndex + 1)"
    }
}
#endif
