#if canImport(FoundationModels)
import Foundation
import Testing

@testable import IssaAsk

/// The one thing the scripted model cannot show: that a sensible question about
/// a real book gets a sensible answer out of Apple's on-device model, in a time
/// a reader will wait for.
///
/// Gated on the model actually being available, because most machines and every
/// CI runner will not have it — and a suite that silently passed by not running
/// would be worse than one that is honestly skipped.
@Suite(.enabled(if: SystemAnswerModel.isAvailableForTesting))
struct SystemAnswerModelTests {
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    @Test("a question the book has answered gets a real answer")
    func answersFromWhatHasBeenRead() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()

        let indexStart = ContinuousClock.now
        try await store.prepare(source: source)
        let indexMilliseconds = Self.elapsedMilliseconds(since: indexStart)

        let engine = AskEngine(model: SystemAnswerModel(), store: store)
        let question = "What did Alice follow down the hole?"
        let askStart = ContinuousClock.now
        var answer: AskAnswer?
        for try await event in engine.ask(
            question: question, source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ) {
            if case let .answered(value) = event { answer = value }
        }
        let askMilliseconds = Self.elapsedMilliseconds(since: askStart)

        let found = try #require(answer)
        print("""
        [ask] index \(indexMilliseconds) ms, answer \(askMilliseconds) ms
        [ask] Q: \(question)
        [ask] A: \(found.text)
        [ask] citations \(found.citations), notYetRevealed \(found.notYetRevealed)
        """)
        #expect(found.text.lowercased().contains("rabbit"))
        #expect(!found.notYetRevealed)
    }

    @Test("a question about a character not yet met gets the sentinel")
    func refusesToSpoil() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()
        try await store.prepare(source: source)

        let engine = AskEngine(model: SystemAnswerModel(), store: store)
        let question = "Who is the Cheshire Cat?"
        let start = ContinuousClock.now
        var answer: AskAnswer?
        for try await event in engine.ask(
            question: question, source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ) {
            if case let .answered(value) = event { answer = value }
        }
        let milliseconds = Self.elapsedMilliseconds(since: start)

        let found = try #require(answer)
        print("""
        [ask] answer \(milliseconds) ms
        [ask] Q: \(question)
        [ask] A: \(found.text)
        [ask] notYetRevealed \(found.notYetRevealed)
        """)
        // The model has read the canon; it knows perfectly well who the
        // Cheshire Cat is. The reader, at the end of Chapter I, does not.
        #expect(found.notYetRevealed)
    }

    @Test("the model's own tokeniser agrees with the estimate to within a third")
    func estimateIsCloseEnoughToBudgetWith() async throws {
        let model = SystemAnswerModel()
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI).prefix(2_000)
        let real = try await model.tokenCount(for: String(text))
        let estimate = AskPromptBuilder.estimatedTokens(String(text))
        print("[ask] tokens real \(real), estimated \(estimate)")
        // The estimate only exists to avoid asking the model to count something
        // obviously far too large; if it drifted badly the first pass would trim
        // passages that would have fitted.
        #expect(Double(estimate) > Double(real) * 0.66)
        #expect(Double(estimate) < Double(real) * 1.5)
        #expect(model.contextSize >= 4_096)
    }

    @Test("availability reads as available on a machine that has the model")
    func availabilityAgrees() {
        #expect(AskAvailability.current() == .available)
        #expect(AskAvailability.current().isReady)
    }
}

/// The translation between the engine's sampler and the framework's.
///
/// Deliberately outside the suite above: this needs the SDK but not the model,
/// so unlike everything else in this file it runs on any machine that can
/// compile FoundationModels — including the ones where the gated suite is
/// skipped, which is where a dropped seed would otherwise go unnoticed.
struct SamplingModeTests {
    @Test("greedy stays greedy, and a seed reaches the framework intact")
    func samplingIsTranslated() {
        #expect(SystemAnswerModel.sampling(for: .greedy) == .greedy)
        #expect(
            SystemAnswerModel.sampling(for: .nucleus(probabilityThreshold: 0.9, seed: 42))
                == .random(probabilityThreshold: 0.9, seed: 42),
        )
        // A seed that did not arrive and a seed that did are the difference
        // between "ask again" and "roll again", and both compile.
        #expect(
            SystemAnswerModel.sampling(for: .nucleus(probabilityThreshold: 0.9, seed: 42))
                != .random(probabilityThreshold: 0.9, seed: 43),
        )
    }
}
#endif
