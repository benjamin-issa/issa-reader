import Foundation
import Testing

@testable import IssaAsk

/// The two engine-level paths that must not reach the model at all, and the
/// one that must.
///
/// A file of its own rather than more cases in `AskEngineTests`, whose helpers
/// these reuse: three streams of this build were editing that file at once, and
/// a new suite is the one shape a merge cannot get wrong.
struct AskEngineRecapTests {
    /// A reader who opens the sheet before reading a word.
    ///
    /// "What has happened so far?" is the first chip on the sheet, so the
    /// question is one tap away from a boundary with nothing behind it. The
    /// recap branch had no emptiness check of its own — every other branch
    /// returns `.notYet(unmet: [])` for "nothing retrieved" — so it ran a
    /// generation over no excerpts, which is several seconds of the model
    /// answering a question about a book it was shown none of.
    @Test("a recap with nothing behind it never reaches the model")
    func emptyRecapShortCircuits() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        // Before the first indexed passage of the first spine, which is where
        // the reader who has just opened the book is standing.
        let boundary = ReadingBoundary(spineIndex: 0, charOffset: 0)
        let retriever = AskRetriever(
            store: store, bookUUID: AskFixture.bookUUID, boundary: boundary,
        )
        let retrieval = try await retriever.retrieve(question: AskSuggestions.recap)
        // Not a `guard`: the engine assertions below are the ones the fix is
        // for, and they must be reached whatever retrieval decided.
        if case let .notYet(unmet) = retrieval {
            // A recap names nobody, so there is nothing for the sheet to report
            // as unmet — the same empty list every other branch returns.
            #expect(unmet.isEmpty)
        } else {
            Issue.record("a recap over no passages should be not-yet")
        }

        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)
        let (events, failure) = await AskEngineTests.drain(engine.ask(
            question: AskSuggestions.recap, source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        // Not `answer.text`: the scripted reply mentions Alice, whom the reader
        // at (0, 0) has not met, so the answer-side guard already replaces it
        // with the sentinel and the text alone says nothing about this fix.
        // What it costs is the model call, so that is what is asserted.
        #expect(await model.received.isEmpty)
        #expect(!events.contains(.phase(.thinking)))
        let answer = try #require(AskEngineTests.answer(events))
        #expect(answer.notYetRevealed)
        #expect(answer.origin == .withheld)
        #expect(answer.sources.isEmpty)
    }

    /// The cost of stripping hesitation for one kind of question only, on the
    /// path a reader takes.
    ///
    /// "wait is Dask Ryn's brother?" asks whether, and the deterministic table
    /// may only answer a question that asks who. With the filler still in front
    /// of the question the yes/no scan never found its copula, the form came
    /// back `.whoIs`, and the fast path answered "Ryn's brother is Dask." —
    /// confidently, out of the book, to a question nobody asked.
    @Test("a yes/no kinship question behind a filler is read by the model, not the table")
    func yesNoAfterFillerGoesToTheModel() async throws {
        let (store, source, boundary, directory) = try AskFixture.syntheticStore(
            chapters: [AskEngineTests.kinshipChapter],
        )
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await AskEngineTests.drain(engine.ask(
            question: "wait is Dask Ryn's brother?", source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        #expect(await model.received.count == 1)
        #expect(events.contains(.phase(.thinking)))
        // The answer itself is the scripted reply's fate, which is beside the
        // point; what matters is that the book did not claim to have said it.
        let answer = try #require(AskEngineTests.answer(events))
        #expect(answer.origin != .book)
    }
}
