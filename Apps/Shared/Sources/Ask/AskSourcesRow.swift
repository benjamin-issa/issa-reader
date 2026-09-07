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
/// `onContentHeight` → `askDetent` path does exactly that for nothing.
///
/// **An answer with sources now opens the large detent, and that is right.**
/// Measured on an iPhone 17 Pro with the first card open by default: the
/// shortest answer the fixture book gives — "Alice has a sister.", one line —
/// makes the stack 360 points, and the longest 450. Both are over the 300-point
/// threshold, but the number that decides it is the medium detent itself: half
/// of 874 is 437, and the sheet has to fit 24 points of padding, a 22-point
/// header, the stack, the pill and 24 more points below it. 360 + 94 is 454, so
/// there is no arrangement in which a card this size fits a half sheet — going
/// large is not the threshold being too low, it is the content being taller
/// than the detent. The compose state, which is where a reader decides whether
/// to type at all, is 300 points with six chips and stays on medium.
struct AskSourcesRow: View {
    let sources: [AskSource]
    /// The chapter each excerpt is in, resolved by the caller: only
    /// `ReaderModel` can name a chapter, and only for a book it has open.
    let title: (AskSource) -> String?
    let onOpen: (AskSource) -> Void

    /// What the reader has done about the cards, which is not the same question
    /// as which card is open. See `AskSourcesOpening`.
    ///
    /// Opened on the first source rather than starting closed, and that is the
    /// answer to "make the answers say more". A prompt arm that asked the model
    /// for four to eight sentences was measured over 157 real generations: it
    /// wrote 34% more words and 83% more unsupported claims, and every *true*
    /// fact it added was already sitting in an excerpt one tap away. So the
    /// extra sentence comes from the book instead, at zero risk of invention —
    /// which is what the sources row was built for and what nobody was tapping.
    @State private var opened = AskSourcesOpening.Opened.untouched

    /// Three. A fourth chip wraps to a second row on a phone, and by the fourth
    /// excerpt the model is citing everything it was handed rather than what it
    /// used.
    static let limit = 3

    private var shown: [AskSource] { Array(sources.prefix(Self.limit)) }

    private var openOrdinal: Int? { AskSourcesOpening.ordinal(opened, in: shown) }

    /// What makes one answer's sources different from another's. Ordinals
    /// alone will not do: two answers about one book both cite `[1, 2, 3]`.
    private var answerKey: [Passage] { shown.map(\.passage) }

    var body: some View {
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.spacing8) {
                Text("Sources").overlineStyle()

                HStack(spacing: Metrics.spacing8) {
                    ForEach(shown) { source in
                        chip(source)
                    }
                }

                if let ordinal = openOrdinal,
                   let source = shown.first(where: { $0.ordinal == ordinal }) {
                    card(source)
                }
            }
            .accessibilityIdentifier("ask.sources")
            // Keyed to the answer, not to the view's lifetime. "Ask another"
            // renders a new answer into this same row, and what the reader
            // decided about the last one's excerpts says nothing about this
            // one's.
            .onChange(of: answerKey) { opened = .untouched }
        }
    }

    // MARK: - Pieces

    /// The suggestion chip's own recipe, so the two rows in this sheet are one
    /// idea rather than two capsule styles that drifted apart.
    private func chip(_ source: AskSource) -> some View {
        let isOpen = openOrdinal == source.ordinal
        return Button {
            opened = AskSourcesOpening.tapping(source.ordinal, from: opened, in: shown)
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

/// Which excerpt the sources row draws open, and what a tap does to it.
///
/// **The sentinel was ambiguous, and the guard built on it could not work.**
/// The state was an `Int?` where nil meant both "never opened" and "the reader
/// closed it". So the `onAppear` that read
/// `if opened == nil { opened = shown.first?.ordinal }` — commented "only when
/// nothing is open, so a reader who closed the card and came back to the sheet
/// is not overruled by it springing open again" — did exactly what it said it
/// would not: a closed card is nil, and nil is what it reopens.
///
/// **And `onAppear` is once per view, not once per answer.** "Ask another"
/// renders a second answer into the same row, so `onAppear` does not fire
/// again and the ordinal from the *previous* answer stands — opening whichever
/// of the new excerpts happens to carry that number, or, when none does,
/// nothing at all under a row of chips that all look shut.
///
/// So: three states, the default derived rather than assigned, and the reset
/// keyed to the answer. Lifted out of the view for the reason `AskSourceLabel`
/// below is — `IssaSharedTests` cannot reach a SwiftUI `View`, and this is the
/// part that was wrong.
enum AskSourcesOpening {
    /// What the reader has done about the cards, which is not the same question
    /// as which card is open.
    enum Opened: Equatable {
        /// Nothing has been decided about *this answer* yet, so the first
        /// source shows itself. Not a stored ordinal: derived, so a row handed
        /// a new answer opens that answer's first source rather than keeping a
        /// number belonging to the last one.
        case untouched
        /// The reader closed the card. Distinct from `untouched`, and the whole
        /// reason this is not an `Int?`.
        case closed
        /// The reader opened this one.
        case source(Int)
    }

    /// The ordinal actually drawn open, or nil for none.
    ///
    /// An ordinal the current answer does not have reads as nothing open,
    /// which is what makes a stale value harmless rather than wrong.
    static func ordinal(_ opened: Opened, in sources: [AskSource]) -> Int? {
        switch opened {
        case .untouched: sources.first?.ordinal
        case .closed: nil
        case let .source(ordinal):
            sources.contains { $0.ordinal == ordinal } ? ordinal : nil
        }
    }

    /// What tapping a chip leaves behind.
    ///
    /// Closing goes to `.closed` and never back to `.untouched`: closing the
    /// card the row opened by itself has to stay closed, and `.untouched` is
    /// the state that opens it again.
    static func tapping(_ ordinal: Int, from opened: Opened, in sources: [AskSource]) -> Opened {
        self.ordinal(opened, in: sources) == ordinal ? .closed : .source(ordinal)
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
