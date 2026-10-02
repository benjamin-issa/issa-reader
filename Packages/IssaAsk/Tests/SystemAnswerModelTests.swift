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
// With `ISSA_RELEASE_RUN=1` the suite runs regardless, and each test's first
// line reports a missing model as an issue — see `ReleaseRun`.
@Suite(.enabled(if: ReleaseRun.shouldRunModelSuites))
struct SystemAnswerModelTests {
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    @Test("a question the book has answered gets a real answer")
    func answersFromWhatHasBeenRead() async throws {
        guard ReleaseRun.requireModel() else { return }
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

    /// The answer-side guard, against the real model.
    ///
    /// This asked "Who is the Cheshire Cat?", which never reaches the model at
    /// all: "cheshire" is unmet at the end of Chapter I, so retrieval answers
    /// `.notYet` from SQL and the model is consulted only for its language and
    /// its window. It passed on the question-side guard alone, and would have
    /// kept passing with `vetted` deleted. A question whose own words are all
    /// met is the one that is put to the model — and the model has read the
    /// book, so what it says is checked against what the reader has.
    @Test("a question the model is asked is answered without spoiling what comes later")
    func refusesToSpoil() async throws {
        guard ReleaseRun.requireModel() else { return }
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()
        try await store.prepare(source: source)

        let engine = AskEngine(model: SystemAnswerModel(), store: store)
        let question = "What does Alice meet in the wood?"
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        let start = ContinuousClock.now
        var answer: AskAnswer?
        var phases: [AskPhase] = []
        for try await event in engine.ask(question: question, source: source, boundary: boundary) {
            switch event {
            case let .answered(value): answer = value
            case let .phase(phase): phases.append(phase)
            case .partial: break
            }
        }
        let milliseconds = Self.elapsedMilliseconds(since: start)

        let found = try #require(answer)
        print("""
        [ask] answer \(milliseconds) ms
        [ask] Q: \(question)
        [ask] A: \(found.text)
        [ask] notYetRevealed \(found.notYetRevealed)
        """)
        // The model was asked: this is the path the question-side guard cannot
        // reach.
        #expect(phases.contains(.thinking))
        // Whatever it said — the sentinel, or an answer — names nobody the
        // reader has not met. The index has the last word, as in the engine.
        if found.notYetRevealed {
            #expect(found.sources.isEmpty)
        } else {
            let candidates = AskEngine.unvettedNames(in: found.text, question: question)
            let unmet = try await store.unmetWords(
                candidates, in: AskFixture.bookUUID, before: boundary,
            )
            #expect(unmet.isEmpty, "\(unmet)")
        }
    }

    @Test("the model's own tokeniser agrees with the estimate to within a third")
    func estimateIsCloseEnoughToBudgetWith() async throws {
        guard ReleaseRun.requireModel() else { return }
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
        guard ReleaseRun.requireModel() else { return }
        #expect(AskAvailability.current() == .available)
        #expect(AskAvailability.current().isReady)
    }
}

/// Which books the model is asked about at all.
///
/// Outside the gated suite: the decision needs the SDK's `Locale.Language`,
/// not the model, and a refusal here is every question about the book.
struct SupportedLanguageTests {
    static let english: [Locale.Language] = [Locale.Language(identifier: "en")]

    @Test("a language written as a name, or as no language, is let through")
    func unknownLanguagesAreAllowed() {
        // `Locale.Language("English").languageCode` is `english` — not nil —
        // so this was refused on every question, before the index was touched.
        for written in ["English", "english", "Deutsch", "und", "mul", "zxx", "", nil] {
            #expect(SystemAnswerModel.supports(written, among: Self.english), "\(written ?? "nil")")
        }
    }

    @Test("a real code is still judged against the model's languages")
    func realCodesAreJudged() {
        for supported in ["en", "en-US", "en_GB", "eng"] {
            #expect(SystemAnswerModel.supports(supported, among: Self.english), "\(supported)")
        }
        for refused in ["fr", "ja", "zh-Hant"] {
            #expect(!SystemAnswerModel.supports(refused, among: Self.english), "\(refused)")
        }
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
}
#endif
