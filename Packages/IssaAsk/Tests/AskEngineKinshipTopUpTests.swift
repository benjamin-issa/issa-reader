import Foundation
import Testing

@testable import IssaAsk

/// The kinship fast path, against the context the retriever adds behind it.
///
/// A suite of its own rather than another case beside
/// `AskEngineTests.kinshipFastPathAnswersOutright`, because that test passes on
/// a tie: the kin sentence's antecedent happens to open its passage, so the
/// window and the paragraph start at the same offset and a stable sort keeps
/// the window in front. One ordinary sentence ahead of it breaks the tie, and
/// everything the fast path is for goes with it.
struct AskEngineKinshipTopUpTests {
    @Test("a sentence before the antecedent does not cost the book its own answer")
    func kinshipFastPathSurvivesTheTopUp() async throws {
        // Two kin sentences is below `kinshipFloor`, so this question is topped
        // up with whole paragraphs — and one of the paragraphs the same query
        // returns is the paragraph the kin sentence was lifted from. Wider
        // window, same text, sorts first: `inBookOrder` kept the paragraph, the
        // extractor refuses to read a paragraph, and a book that states the
        // answer in so many words went to the model instead.
        var chapter = AskEngineTests.kinshipChapter
        chapter[0] = "The rain had not stopped for a week. " + chapter[0]
        let (store, source, boundary, directory) = try AskFixture.syntheticStore(
            chapters: [chapter],
        )
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await AskEngineTests.drain(engine.ask(
            question: "What is the name of Ryn's brother?", source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        let answer = try #require(AskEngineTests.answer(events))
        #expect(answer.text == "Ryn's brother is Dask.")
        // Nothing composed it, and nothing was asked to.
        #expect(answer.origin == .book)
        #expect(await model.received.isEmpty)
        #expect(!events.contains(.phase(.thinking)))
    }
}
