#if canImport(FoundationModels)
import Foundation
import Testing

@testable import IssaAsk

/// The eight questions, asked of Apple's model on a machine that has it.
///
/// The deterministic suites prove the retrieval is right. This proves the only
/// thing they cannot: that the sentences retrieval chose are enough for a 3B
/// model to answer from, and that the ones it must not see are not there. It is
/// the shape of the run that caught the original defect — "Who is Vin?"
/// answered from passing mentions, "What is the name of Vin's brother?"
/// answered "Quellion" — and neither would have shown up in a suite with no
/// model in it.
///
/// Gated, because most machines and every CI runner have no model, and a suite
/// that silently passed by not running would be worse than one honestly
/// skipped.
@Suite(.enabled(if: SystemAnswerModel.isAvailableForTesting))
struct RegressionQuestionsTests {
    @Test("every fixture question is answered from what the reader has read")
    func answersEveryFixtureQuestion() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()
        try await store.prepare(source: source)
        let engine = AskEngine(model: SystemAnswerModel(), store: store)

        for fixture in try AskQuestionFixture.all() {
            let boundary = try fixture.boundary
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

            print("""
            [ask] \(fixture.name) — spine \(fixture.spine), \(milliseconds) ms
            [ask] Q: \(fixture.question)
            [ask] A: \(found.text)
            [ask] citations \(found.citations), notYetRevealed \(found.notYetRevealed)
            """)

            let lowered = found.text.lowercased()
            if let notYet = fixture.notYet {
                #expect(found.notYetRevealed == notYet, "\(fixture.name)")
            }
            // `.thinking` is yielded only when the model is about to be asked,
            // so it is the observable form of "was the model called".
            #expect(phases.contains(.thinking) == fixture.modelCalled, "\(fixture.name)")
            if !fixture.answerContainsAny.isEmpty, !found.notYetRevealed {
                #expect(
                    fixture.answerContainsAny.contains { lowered.range(of: $0) != nil },
                    "\(fixture.name): \(found.text)",
                )
            }
            for needle in fixture.answerExcludes {
                #expect(!lowered.contains(needle), "\(fixture.name): leaked \(needle)")
            }
            if !fixture.allowsNewNames, !found.notYetRevealed {
                // A name the question did not ask about and the book has not
                // introduced is the one thing this feature promised not to do.
                let introduced = AskEngine.unvettedNames(
                    in: found.text, question: fixture.question,
                )
                #expect(introduced.isEmpty, "\(fixture.name): \(introduced)")
            }
        }
    }
}
#endif
