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
    /// At least one of these must appear in the answer. Empty means no
    /// particular wording is right — the degradation cases.
    ///
    /// Never emptied to make a case pass. "Who is the author's father?" was:
    /// it answered *Benjamin* Franklin once — the book's own author rather than
    /// his father — which is why the question is in this file at all; it was
    /// fixed, it answered *Josiah* Franklin for several releases, and when the
    /// renderer stopped keeping the stray space between two blocks on
    /// 2026-09-17 it stopped naming him, and this list was blanked as a model
    /// wobble that no test should pin.
    ///
    /// It was not a wobble. The sentence that answers the question — "Josiah,
    /// my father, married young, and carried his wife with three children into
    /// New England" — had never been retrieved: `father` is a known name in
    /// this book ("Father Abraham"), so it became the subject, and every
    /// passage had to contain "father" *and* one of "who", "mother",
    /// "parents"…, which that sentence does not. The model was handed four
    /// excerpts that never said who the father was, and its answer turned on
    /// an epitaph's "Josiah Franklin" — which greedy decoding over slightly
    /// different whitespace stopped reaching. Retrieval was the fix (see
    /// `AskRetriever.optionalTerms(_:subject:)`), `evidenceContains` now pins
    /// the sentence itself, and the answer names him again.
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

    /// Whether the answer names one of `answerContainsAny`; nil when the
    /// fixture pins no wording.
    ///
    /// **The sentinel is a failure here, not a pass.** It was nil — "either is
    /// acceptable" — so a prompt or a guard that refused every answerable
    /// question still scored every fixture: the model was called, the refusal
    /// contains none of the excluded words, and the new-names check skips a
    /// refusal. A fixture with an expected answer is one the reader has read
    /// far enough to be told; "the story hasn't revealed that yet" is the
    /// wrong answer to it. A fixture where a refusal is right says so with
    /// `notYet`.
    func containsExpected(in answer: AskAnswer) -> Bool? {
        guard !answerContainsAny.isEmpty else { return nil }
        guard !answer.notYetRevealed else { return false }
        let lowered = answer.text.lowercased()
        return answerContainsAny.contains { lowered.range(of: $0) != nil }
    }

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

/// The regression suite's checks, without the model: what it counts as a pass
/// has to be right before what the model says can mean anything.
struct AskQuestionFixtureTests {
    static func fixture(expecting words: [String]) -> AskQuestionFixture {
        AskQuestionFixture(
            name: "test", question: "Who is the author's father?", spine: 2, kind: "general",
            evidenceContains: [], evidenceExcludes: [], answerContainsAny: words,
            answerExcludes: [], notYet: nil, modelCalled: true, kinshipNames: nil,
            allowsNewNames: true,
        )
    }

    @Test("a refusal fails a question the reader has read far enough to be answered")
    func refusalFailsAnAnswerableFixture() {
        let refusal = AskAnswer(
            text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
            origin: .withheld,
        )
        #expect(Self.fixture(expecting: ["josiah"]).containsExpected(in: refusal) == false)
        // A fixture that pins no wording is still indifferent to it.
        #expect(Self.fixture(expecting: []).containsExpected(in: refusal) == nil)
    }

    @Test("an answer is judged by its words")
    func answersAreJudgedByTheirWords() {
        let named = AskAnswer(text: "His father was Josiah Franklin.", citations: [1],
                              notYetRevealed: false)
        let unnamed = AskAnswer(text: "His father was a tradesman.", citations: [1],
                                notYetRevealed: false)
        #expect(Self.fixture(expecting: ["josiah"]).containsExpected(in: named) == true)
        #expect(Self.fixture(expecting: ["josiah"]).containsExpected(in: unnamed) == false)
    }
}
