#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import Testing

@testable import IssaAsk

/// Every fixture question, asked of Apple's model on a machine that has it.
///
/// The deterministic suites prove the retrieval is right. This proves the only
/// thing they cannot: that the sentences retrieval chose are enough for a 3B
/// model to answer from, and that the ones it must not see are not there. It is
/// the shape of the run that caught the original defect — "Who is Ryn?"
/// answered from passing mentions, "What is the name of Ryn's brother?"
/// answered "Sorrel" — and neither would have shown up in a suite with no
/// model in it.
///
/// Both books, because the second defect it now guards is only visible on the
/// second one: "What happened to the author's son?" answered "The author's son
/// died." from a paragraph about Dr Mandeville, and there is no such question
/// to ask of *Alice*.
///
/// Gated, because most machines and every CI runner have no model, and a suite
/// that silently passed by not running would be worse than one honestly
/// skipped.
@Suite(.enabled(if: SystemAnswerModel.isAvailableForTesting))
struct RegressionQuestionsTests {
    @Test("every fixture question is answered from what the reader has read")
    func answersEveryFixtureQuestion() async throws {
        for (book, questions) in AskQuestionFixture.books() {
            let run = try await RegressionRun(book: book)
            defer { run.tearDown() }
            for fixture in try AskQuestionFixture.all(questions) {
                let outcome = try await run.ask(fixture)
                outcome.printSummary()
                outcome.assert()
            }
        }
    }
}

/// One book, indexed once, asked any number of questions.
///
/// Shared between the regression suite, which asserts, and the scorecard, which
/// records — so the two can never drift into measuring different things.
struct RegressionRun {
    let book: AskBook
    let directory: URL
    let store: AskIndexStore
    let source: BookSource
    let engine: AskEngine
    let model: SystemAnswerModel

    init(book: AskBook) async throws {
        self.book = book
        directory = try AskFixture.temporaryDirectory()
        store = AskIndexStore(directory: directory)
        source = try book.source()
        try await store.prepare(source: source)
        model = SystemAnswerModel()
        engine = AskEngine(model: model, store: store)
    }

    func tearDown() { AskFixture.remove(directory) }

    /// What one question came back with, and every fact the assertions and the
    /// scorecard read off it.
    struct Outcome: Encodable {
        var book: String
        var name: String
        var question: String
        var spine: Int
        var milliseconds: Int
        var answer: String
        var citations: [Int]
        var notYetRevealed: Bool
        var modelCalled: Bool
        /// Nil when the fixture has no expectation, or the sentinel came back.
        var containsExpected: Bool?
        var leaked: [String]
        /// Names the answer introduced that the read part of the book had not.
        var newNames: [String]
        var answerWords: Int
        var expectedNotYet: Bool?
        var expectedModelCalled: Bool
        var allowsNewNames: Bool
        var modelDescription: String
        var contextSize: Int

        func printSummary() {
            print("""
            [ask] \(book) — \(name) — spine \(spine), \(milliseconds) ms
            [ask] Q: \(question)
            [ask] A: \(answer)
            [ask] citations \(citations), notYetRevealed \(notYetRevealed), newNames \(newNames)
            """)
        }

        func assert() {
            if let expectedNotYet {
                #expect(notYetRevealed == expectedNotYet, "\(name)")
            }
            #expect(modelCalled == expectedModelCalled, "\(name)")
            if let containsExpected {
                #expect(containsExpected, "\(name): \(answer)")
            }
            #expect(leaked.isEmpty, "\(name): leaked \(leaked)")
            if !allowsNewNames, !notYetRevealed {
                // A name the question did not ask about and the book has not
                // introduced is the one thing this feature promised not to do.
                #expect(newNames.isEmpty, "\(name): \(newNames)")
            }
        }

        /// Whether every assertion would pass, for the scorecard's tally.
        var passes: Bool {
            (expectedNotYet.map { $0 == notYetRevealed } ?? true)
                && modelCalled == expectedModelCalled
                && (containsExpected ?? true)
                && leaked.isEmpty
                && (allowsNewNames || notYetRevealed || newNames.isEmpty)
        }
    }

    func ask(_ fixture: AskQuestionFixture) async throws -> Outcome {
        let boundary = try fixture.boundary(in: book)
        let start = ContinuousClock.now
        var answer: AskAnswer?
        var phases: [AskPhase] = []
        for try await event in engine.ask(
            question: fixture.question, source: source, boundary: boundary,
        ) {
            switch event {
            case let .answered(value): answer = value
            case let .phase(phase): phases.append(phase)
            case .partial: break
            }
        }
        let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
        let found = try #require(answer, "\(fixture.name)")
        let lowered = found.text.lowercased()

        // Asserted through the index, which is the guard the engine actually
        // applies. `unvettedNames` alone is deliberately generous — it catches
        // "Rome" and "Cooks" so the probe can clear them — so the store has the
        // last word.
        let candidates = AskEngine.unvettedNames(in: found.text, question: fixture.question)
        let newNames = try await store.unmetWords(candidates, in: book.bookUUID, before: boundary)

        return Outcome(
            book: book.resource,
            name: fixture.name,
            question: fixture.question,
            spine: fixture.spine,
            milliseconds: milliseconds,
            answer: found.text,
            citations: found.citations,
            notYetRevealed: found.notYetRevealed,
            // `.thinking` is yielded only when the model is about to be asked,
            // so it is the observable form of "was the model called".
            modelCalled: phases.contains(.thinking),
            containsExpected: fixture.answerContainsAny.isEmpty || found.notYetRevealed
                ? nil
                : fixture.answerContainsAny.contains { lowered.range(of: $0) != nil },
            leaked: fixture.answerExcludes.filter { lowered.contains($0) },
            newNames: Array(newNames).sorted(),
            answerWords: found.text.split(whereSeparator: \.isWhitespace).count,
            expectedNotYet: fixture.notYet,
            expectedModelCalled: fixture.modelCalled,
            allowsNewNames: fixture.allowsNewNames,
            modelDescription: model.modelDescription,
            contextSize: model.contextSize,
        )
    }
}
#endif
