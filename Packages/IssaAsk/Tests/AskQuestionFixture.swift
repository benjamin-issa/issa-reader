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
    /// At least one of these must appear in the answer.
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
