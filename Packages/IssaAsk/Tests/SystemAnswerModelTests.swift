#if canImport(FoundationModels) && !os(tvOS)
import Foundation
import FoundationModels
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

        let model = SystemAnswerModel()
        let engine = AskEngine(model: model, store: store)
        let question = "What did Alice follow down the hole?"
        let askStart = ContinuousClock.now
        var answer: AskAnswer?
        // The last partial is what the model actually said, before the engine
        // vetted it — the thing to read when the answer below is the sentinel.
        var streamed = ""
        for try await event in engine.ask(
            question: question, source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ) {
            switch event {
            case let .answered(value): answer = value
            case let .partial(text): streamed = text
            case .phase: break
            }
        }
        let askMilliseconds = Self.elapsedMilliseconds(since: askStart)

        let found = try #require(answer)
        print("""
        [ask] \(model.modelDescription); index \(indexMilliseconds) ms, answer \(askMilliseconds) ms
        [ask] Q: \(question)
        [ask] A: \(found.text)
        [ask] streamed: \(streamed)
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

/// The error table, case by case, with errors built from the framework's own
/// public initialisers.
///
/// Outside the gated suite for the same reason `SamplingModeTests` is: this
/// needs the SDK, not the model, and the table is exactly the kind of thing
/// that ships inert when a framework renames its cases — which the 27 SDK did.
struct FailureTableTests {
    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @Test("every 27 error lands on the failure the engine expects")
    func currentTable() {
        let context = LanguageModelError.contextSizeExceeded(
            .init(contextSize: 4_096, tokenCount: 5_000, debugDescription: "test"))
        #expect(SystemAnswerModel.failure(for: context) == .tooMuchContext)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.guardrailViolation(
            .init(debugDescription: "test"))) == .declined)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.refusal(
            .init(explanation: "no", debugDescription: "test"))) == .declined)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.unsupportedLanguageOrLocale(
            .init(languageCode: .init("xx"), debugDescription: "test"))) == .unsupportedLanguage)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.rateLimited(
            .init(resetDate: nil, debugDescription: "test"))) == .busy)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.timeout(
            .init(debugDescription: "test"))) == .timedOut)
        #expect(SystemAnswerModel.failure(for: LanguageModelError.unsupportedGenerationGuide(
            .init(schemaName: nil, debugDescription: "test")))
            == .other(SystemAnswerModel.couldNotAnswer))
        #expect(SystemAnswerModel.failure(for: SystemLanguageModel.Error.assetsUnavailable(
            .init(debugDescription: "test"))) == .modelDownloading)
        #expect(SystemAnswerModel.failure(for: LanguageModelSession.Error.concurrentRequests) == .busy)
    }

    @available(iOS 27.0, macOS 27.0, visionOS 27.0, *)
    @Test("a tool's failure is judged by what was under it")
    func toolCallUnwraps() {
        let inner = LanguageModelError.timeout(.init(debugDescription: "test"))
        let wrapped = LanguageModelSession.ToolCallError(
            tool: FailureTableTests.Probe(), underlyingError: inner)
        #expect(SystemAnswerModel.failure(for: wrapped) == .timedOut)
    }

    /// The 26 table, still reachable from a 26 device: the same cases the
    /// original switch mapped, mapped the same way.
    @available(iOS, deprecated: 27.0)
    @available(macOS, deprecated: 27.0)
    @available(visionOS, deprecated: 27.0)
    @Test("the 26 table survived the move")
    func legacyTable() {
        typealias Legacy = LanguageModelSession.GenerationError
        let context = Legacy.Context(debugDescription: "test")
        #expect(SystemAnswerModel.failure(for: Legacy.exceededContextWindowSize(context)) == .tooMuchContext)
        #expect(SystemAnswerModel.failure(for: Legacy.assetsUnavailable(context)) == .modelDownloading)
        #expect(SystemAnswerModel.failure(for: Legacy.guardrailViolation(context)) == .declined)
        #expect(SystemAnswerModel.failure(for: Legacy.refusal(.init(transcriptEntries: []), context)) == .declined)
        #expect(SystemAnswerModel.failure(for: Legacy.unsupportedLanguageOrLocale(context)) == .unsupportedLanguage)
        #expect(SystemAnswerModel.failure(for: Legacy.rateLimited(context)) == .busy)
        #expect(SystemAnswerModel.failure(for: Legacy.concurrentRequests(context)) == .busy)
        #expect(SystemAnswerModel.failure(for: Legacy.decodingFailure(context))
            == .other(SystemAnswerModel.couldNotAnswer))
    }

    @Test("an error from neither family is reported, not mislabelled")
    func unknownFamily() {
        struct Stray: Error {}
        #expect(SystemAnswerModel.failure(for: Stray()) == .other(SystemAnswerModel.couldNotAnswer))
    }

    @Test("a timeout tells the reader to try again, not to wait")
    func timeoutSentence() {
        let sentence = AskFailure.timedOut.message(deviceNoun: "Mac")
        #expect(sentence.contains("Try again"))
        #expect(!sentence.lowercased().contains("busy"))
    }

    /// The smallest possible tool, so a `ToolCallError` can be built.
    struct Probe: Tool {
        let name = "probe"
        let description = "A tool that exists so an error can name it."
        @Generable struct Arguments { var query: String }
        func call(arguments: Arguments) async throws -> String { "" }
    }
}
#endif
