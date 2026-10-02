import Foundation
import Testing

@testable import IssaAsk

/// What must not move when the *rendering* of a chapter changes without its
/// words changing.
///
/// Written after one did. On 2026-09-17 the renderer stopped keeping the space
/// that pretty-printed markup leaves between two blocks — `</p>\n<p>` had been
/// collapsing to a space and keeping it, so every paragraph but the first began
/// with one. That is a change to the chapter string, and the index is measured
/// in that string, so the question "what else moved?" had to be answered by
/// experiment rather than by reading.
///
/// It was answered: nothing moved. Retrieval chose the same passages in the
/// same order for all fifteen fixture questions, and the prompt carried the
/// same ones with none dropped. These two tests are that answer written down,
/// so the next change of the same shape is checked rather than re-investigated.
///
/// The suite is deliberately about *inter-block* whitespace. Interior spacing
/// inside a passage does change the characters the model is tokenising, and no
/// test can hold a language model's wording still — see the note on
/// `AskQuestionFixture.answerContainsAny`.
@Suite("Whitespace between blocks moves nothing")
struct WhitespaceStabilityTests {
    /// A chapter as the renderer emits it, and the same chapter as it used to
    /// be emitted — one space after every newline.
    static let chapter = """
    The Wart was the youngest of them, and the least considered.
    He had a way of standing quite still, so that the others forgot him.
    Sir Ector had two sons, and one of them was not his.
    Nobody said so aloud, which is how a thing is said loudest.
    Kay was the elder and the louder, and the one who would be knighted.
    The Wart carried the arrows and said nothing about it at all.
    """

    static var withStraySpaces: String {
        spaced(chapter)
    }

    static func spaced(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\n ")
    }

    /// A chapter with decisions in it for the chunker to make.
    ///
    /// The six lines above are seventy-five words, which the chunker merges
    /// into one passage whatever the spacing — so a comparison over them
    /// compared one whole chapter with its twin, and no boundary could move.
    /// This one has short paragraphs that merge until a passage is full and
    /// then start the next (so there are boundaries to move), and one paragraph
    /// past `maximumWords` (so the sentence splitter runs).
    static let decidingChapter: String = {
        let short = (1 ... 9).map { index in
            "On the \(index) day the Wart carried the arrows out to the butts for Kay, and "
                + "stood at the back of the yard while the elder boy shot, and said nothing "
                + "about it to anybody at supper."
        }
        let long = (1 ... 8).map { index in
            "Sir Ector watched them from the wall on the \(index) evening and thought about "
                + "the letter that had come with the second boy."
        }.joined(separator: " ")
        return (short.prefix(5) + [long] + short.dropFirst(5)).joined(separator: "\n")
    }()

    /// Text as its words, so a comparison is about what was chosen rather than
    /// how it was spaced.
    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }

    /// The property the experiment established: the same words are cut into the
    /// same passages, in the same order, however the blocks were spaced.
    ///
    /// The comparison is on the *words*, not the bytes, and that distinction is
    /// the finding rather than a convenience. `displayText` trims a passage's
    /// ends and nothing else, so a passage spanning several blocks keeps the
    /// whitespace between them — which is exactly the whitespace that changed.
    /// Asserting byte equality here fails, and it should: what the reader must
    /// be able to rely on is that the same prose is chosen and cut the same
    /// way, not that it is spaced identically.
    ///
    /// `start`, `end` and `text` are likewise allowed to differ — they shift by
    /// the removed whitespace, which is the change itself.
    /// `IndexOffsetTests.chunkingIsReproducible` asserts strict `Passage`
    /// equality against one string, which is a different property and cannot
    /// catch this.
    @Test("the same words are chunked the same way, however the blocks are spaced")
    func chunkingIgnoresBlockWhitespace() throws {
        let tidy = PassageChunker.indexable(text: Self.decidingChapter, spineIndex: 3)
        let stray = PassageChunker.indexable(
            text: Self.spaced(Self.decidingChapter), spineIndex: 3,
        )

        // The fixture's own shape first, or the comparison below proves
        // nothing: several passages, so merges stopped somewhere, and the long
        // paragraph's opening and closing sentences in different ones, so the
        // splitter cut it.
        try #require(tidy.count >= 3)
        let long = try #require(Self.decidingChapter.split(separator: "\n")
            .first { PassageChunker.wordCount(String($0)) > PassageChunker.Limits.maximumWords })
        // Its sentences differ only in the evening they name.
        let opening = "on the 1 evening", closing = "on the 8 evening"
        try #require(long.contains(opening) && long.contains(closing))
        let holdsOpening = tidy.firstIndex { $0.text.contains(opening) }
        let holdsClosing = tidy.firstIndex { $0.text.contains(closing) }
        try #require(holdsOpening != nil && holdsClosing != nil)
        try #require(holdsOpening != holdsClosing)

        #expect(tidy.count == stray.count)
        for (a, b) in zip(tidy, stray) {
            #expect(a.ordinal == b.ordinal)
            #expect(a.spineIndex == b.spineIndex)
            // What the model is shown, compared as words: see above.
            #expect(Self.words(a.displayText) == Self.words(b.displayText))
            // The word count is what the merge and split decisions are made on,
            // so a whitespace change that moved it would move the boundaries.
            #expect(a.words == b.words)
        }
    }

    /// The other half: even where a passage's stored text still carries leading
    /// whitespace, its rank must not depend on it.
    ///
    /// `score` is `public` with a doc comment saying it is public so a test can
    /// assert the arithmetic; this is that test.
    @Test("a passage's score does not depend on the whitespace around it")
    func scoreIgnoresSurroundingWhitespace() {
        let terms = QueryTerms.extract(
            from: "Who is the Wart's brother?", knownNames: ["wart", "kay"],
        )
        func passage(_ text: String) -> RetrievedPassage {
            RetrievedPassage(
                passage: Passage(
                    spineIndex: 3, ordinal: 7, start: 100, end: 100 + (text as NSString).length,
                    words: PassageChunker.wordCount(text), text: text,
                ),
                bm25: -4.25,
                isTruncated: false,
            )
        }
        let bare = "Kay was the elder, and the Wart carried his arrows."
        for spaced in [" \(bare)", "\(bare) ", "  \(bare)\n"] {
            #expect(
                PassageRanker.score(passage(bare), terms: terms, isRecent: false)
                    == PassageRanker.score(passage(spaced), terms: terms, isRecent: false),
                "\(spaced.debugDescription) scored differently")
        }
    }
}
