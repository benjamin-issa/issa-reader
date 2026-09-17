import Foundation
import Testing

@testable import IssaAsk

/// The questions both regression suites are written against.
///
/// One file rather than two lists, because the deterministic assertions and the
/// real-model ones are about the same questions and drifting apart is exactly
/// how a regression suite stops meaning anything. The `evidence` expectations
/// are a function of the book and are checked without a model; the `answer`
/// ones are checked only when Apple's model is actually available, and are kept
/// loose on purpose — the retrieval is deterministic and the model is not.
///
/// Two books. *Alice* is eight questions about a novel; *Franklin* is six about
/// a memoir, and exists because a novel cannot ask "What happened to the
/// author's son?" — the question that was measured retrieving one paragraph
/// about Dr Mandeville and Isaac Newton, and answered "The author's son died."
struct AskQuestionFixture: Decodable, Sendable {
    /// What the case is for, printed beside the answer.
    var name: String
    var question: String
    /// The spine index the reader has finished. 2 is Chapter I, 3 Chapter II,
    /// 7 Chapter VI.
    var spine: Int
    /// `identity`, `kinship`, `general` or `recap`.
    var kind: String
    /// Lowercased substrings that must all appear across the excerpts.
    var evidenceContains: [String]
    /// …and that must not appear in any of them.
    var evidenceExcludes: [String]
    /// At least one of these must appear in the answer. Empty means the
    /// question's wording is not pinned — either because no particular answer
    /// is right (the degradation cases) or because one was pinned and the model
    /// has since moved off it.
    ///
    /// One case is the latter, and what moved it is worth writing down, because
    /// the first two explanations given for it were both wrong.
    ///
    /// "Who is the author's father?" answered *Benjamin* Franklin once — the
    /// book's own author rather than his father — which is why the question is
    /// in this file at all; it was fixed, and it answered *Josiah* Franklin for
    /// several releases. On 2026-09-17 the renderer stopped keeping the stray
    /// space that pretty-printed markup leaves between two blocks, and the
    /// answer stopped naming him.
    ///
    /// It was first recorded here that shortening the excerpts let one more of
    /// them fit the model's budget. **That is not what happened**, and it was
    /// asserted without being measured. Both versions were then run side by
    /// side over every question in this file, dumping what retrieval chose and
    /// what the prompt carried:
    ///
    /// - retrieval chose the **same four passages, in the same order**;
    /// - the prompt carried **all four, in both**, dropping none;
    /// - the prompt was *longer* afterwards, 526 tokens against 529, even
    ///   though the text had lost characters.
    ///
    /// So nothing was selected differently. What changed is how the same prose
    /// tokenises once a space between two paragraphs is gone, and generation is
    /// greedy (`usesNucleusSampling = false`), so one different token at the
    /// front is a different answer all the way down. Six of the fifteen
    /// questions reworded; five of the six were harmless and this one was not.
    ///
    /// Which is why it is recorded rather than asserted away: there is nothing
    /// in retrieval to fix, pinning a wording pins the model rather than the
    /// feature, and no prompt change ships on one question. `evidenceContains`
    /// still checks the excerpts, and `leaked` and `newNames` still check the
    /// answer — see `WhitespaceStabilityTests` for what is now held down.
    var answerContainsAny: [String]
    /// None of these may.
    var answerExcludes: [String]
    /// Whether the answer must be the "not yet revealed" sentinel. Nil means
    /// either is acceptable.
    var notYet: Bool?
    /// Whether the model should have been asked at all.
    var modelCalled: Bool
    /// How many names the deterministic kinship table should find.
    var kinshipNames: Int?
    /// Whether the answer may introduce a proper noun the question did not.
    var allowsNewNames: Bool

    static func all(_ resource: String = "Fixtures/questions-alice") throws
        -> [AskQuestionFixture] {
        let url = try #require(Bundle.module.url(forResource: resource, withExtension: "json"))
        let decoded = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
        return decoded.questions
    }

    /// Every book with questions written for it, so a suite covers both by
    /// iterating rather than by remembering to add the second one.
    static func books() -> [(book: AskBook, questions: String)] {
        [
            (AskFixture.alice, "Fixtures/questions-alice"),
            (AskFixture.franklin, "Fixtures/questions-franklin"),
        ]
    }

    private struct File: Decodable {
        var questions: [AskQuestionFixture]
    }

    func boundary(in book: AskBook) throws -> ReadingBoundary {
        try book.endOf(spine: spine)
    }
}
