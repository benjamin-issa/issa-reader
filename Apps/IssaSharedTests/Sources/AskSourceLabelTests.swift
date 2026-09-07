import Foundation
import IssaAsk
import Testing

@testable import IssaReader_iOS

/// The two strings under an answer's source chips.
///
/// They live outside `AskSourcesRow` for the reason `TVPageMetrics` and
/// `ReadingBoundary` live outside their views: this bundle cannot reach a
/// SwiftUI `View` at all, and a decision that can only be checked by looking at
/// a running phone is a decision nothing checks. Both of these have a wrong
/// answer that ships silently — a chip cut mid-word reads as a rendering fault,
/// and a card headed by an empty string reads as a missing chapter.
@Suite("What a cited excerpt is called")
struct AskSourceLabelTests {
    static func source(
        ordinal: Int = 1, spine: Int = 0, text: String,
    ) -> AskSource {
        AskSource(
            ordinal: ordinal,
            passage: Passage(
                spineIndex: spine, ordinal: 0, start: 0, end: (text as NSString).length,
                words: text.split(whereSeparator: \.isWhitespace).count, text: text,
            ),
        )
    }

    // MARK: - The chip

    @Test("a short excerpt is quoted whole")
    func shortExcerptIsNotCut() {
        #expect(AskSourceLabel.chip(Self.source(text: "a White Rabbit")) == "“a White Rabbit”")
    }

    @Test("a long excerpt is cut at a word boundary, never mid-word")
    func cutsAtAWordBoundary() {
        // "…a White Rab…" reads as a rendering fault rather than a quotation,
        // and there are up to three of these on one line.
        let chip = AskSourceLabel.chip(Self.source(
            text: "when suddenly a White Rabbit with pink eyes ran close by her",
        ))
        #expect(chip.hasPrefix("“when suddenly"))
        #expect(chip.hasSuffix("…”"))
        let quoted = chip.dropFirst().dropLast(2)
        #expect(quoted.count <= 32)
        #expect(!quoted.hasSuffix(" "))
        // Every word in it is a whole word of the excerpt.
        for word in quoted.split(separator: " ") {
            #expect("when suddenly a White Rabbit with pink eyes ran close by her"
                .split(separator: " ").contains(word))
        }
    }

    @Test("the newlines a passage carries from the page never reach the chip")
    func collapsesWhitespace() {
        // A passage keeps the whitespace the chapter's tiling gave it — leading
        // spaces and the newlines between paragraphs — and a chip is one line.
        let chip = AskSourceLabel.chip(Self.source(text: "  Down,\n   down,\n  down.  "))
        #expect(chip == "“Down, down, down.”")
    }

    @Test("an excerpt with nothing readable in it falls back to its number")
    func emptyExcerptFallsBackToTheOrdinal() {
        #expect(AskSourceLabel.chip(Self.source(ordinal: 4, text: "   \n  ")) == "4")
    }

    // MARK: - The card's heading

    @Test("the chapter's own name is what the card is headed with")
    func prefersTheChapterTitle() {
        #expect(AskSourceLabel.heading(
            Self.source(spine: 2, text: "…"), title: "Chapter I",
        ) == "Chapter I")
    }

    @Test("a book that never named the chapter is headed by the section the model was shown")
    func fallsBackToTheSectionNumber() {
        // The same number the excerpt carried in the prompt — `[1] (Section 3)`
        // — so the card and the citation the model wrote agree.
        #expect(AskSourceLabel.heading(Self.source(spine: 2, text: "…"), title: nil)
            == "Section 3")
        // A navigation entry with a blank title is a real EPUB, and it must not
        // produce a card headed by nothing at all.
        #expect(AskSourceLabel.heading(Self.source(spine: 0, text: "…"), title: "  ")
            == "Section 1")
    }
}
