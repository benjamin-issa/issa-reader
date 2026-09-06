import Foundation
import Testing

@testable import IssaAsk

/// The pipeline, driven by a model whose answers are a function of nothing.
///
/// Every property here is one the real model cannot be made to demonstrate: it
/// is not deterministic, it takes seconds per call, and it is unavailable on
/// most machines. The scripted model is what makes "the retry shrinks the
/// prompt" and "the short-circuit never calls the model" into assertions rather
/// than hopes.
struct AskEngineTests {
    /// Collects a whole run.
    static func drain(
        _ stream: AsyncThrowingStream<AskEvent, any Error>,
    ) async -> (events: [AskEvent], failure: (any Error)?) {
        var events: [AskEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    static func partials(_ events: [AskEvent]) -> [String] {
        events.compactMap { if case let .partial(text) = $0 { text } else { nil } }
    }

    static func answer(_ events: [AskEvent]) -> AskAnswer? {
        events.compactMap { if case let .answered(answer) = $0 { answer } else { nil } }.last
    }

    // MARK: - The happy path

    @Test("partials arrive, then the answer")
    func streamsPartialsThenAnswers() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [Turn(partials: [
            "Alice",
            "Alice follows a white rabbit",
            "Alice follows a white rabbit down a hole.\nSources: 1, 2",
        ])])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        #expect(Self.partials(events) == [
            "Alice", "Alice follows a white rabbit",
            "Alice follows a white rabbit down a hole.",
        ])
        let answer = try #require(Self.answer(events))
        #expect(answer.text == "Alice follows a white rabbit down a hole.")
        #expect(answer.citations == [1, 2])
        #expect(events.contains(.phase(.retrieving)))
        #expect(events.contains(.phase(.thinking)))
        #expect(events.contains(.phase(.answering)))
    }

    @Test("the model is given the excerpts, and never the title")
    func promptCarriesExcerptsNotIdentity() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        _ = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        let sent = try #require(await model.received.first)
        #expect(sent.instructions == AskPromptBuilder.instructions)
        #expect(sent.prompt.contains("What did Alice follow down the hole?"))
        #expect(sent.prompt.contains("[1] (Section"))
        let title = try #require(AskFixture.package().metadata.title)
        #expect(!sent.prompt.contains(title))
        #expect(sent.options.temperature == 0)
        #expect(sent.options.maximumResponseTokens == AskPromptBuilder.Budget.responseTokens)
    }

    // MARK: - Retrying a prompt that did not fit

    @Test("a context-window failure retries with a shorter prompt")
    func contextRetryShrinksThePrompt() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(failure: AskFailure.tooMuchContext),
            Turn.answer("She followed a white rabbit.\nSources: 1"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        ))
        #expect(failure == nil)
        #expect(Self.answer(events) != nil)

        let sent = await model.received
        try #require(sent.count == 2)
        // The retry has to be smaller, or it will fail exactly the same way and
        // the reader will have waited twice as long to be told so.
        #expect(sent[1].prompt.count < sent[0].prompt.count)
    }

    @Test("a prompt that never fits fails as too much context, after three tries")
    func givesUpAfterTheSecondRetry() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [Turn(failure: AskFailure.tooMuchContext)])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        ))
        #expect(Self.answer(events) == nil)
        #expect(failure as? AskFailure == .tooMuchContext)
        // All of them, then half, then two.
        #expect(await model.received.count == 3)
    }

    // MARK: - Failures

    @Test("a guardrail refusal ends the stream as a failure, not an answer")
    func guardrailBecomesAFailure() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [Turn(failure: AskFailure.declined)])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(Self.answer(events) == nil)
        #expect(failure as? AskFailure == .declined)
    }

    @Test("an unrecognised error becomes a sentence, never a framework string")
    func unknownErrorsAreComposed() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(failure: ScriptedAnswerModel.ScriptedError.scripted),
        ])
        let engine = AskEngine(model: model, store: store)

        let (_, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?",
            source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        let composed = try #require(failure as? AskFailure)
        if case let .other(message) = composed {
            #expect(!message.contains("Scripted"))
            #expect(message.hasSuffix("Try again."))
        } else {
            Issue.record("expected a composed message, got \(composed)")
        }
    }

    @Test("a book in a language the model cannot read fails before the index is touched")
    func unsupportedLanguageIsPreflighted() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let store = AskIndexStore(directory: directory)
        let source = try AskFixture.source()
        // The fixture is `en`; this model reads only French.
        let model = ScriptedAnswerModel(supportedLanguages: ["fr"])
        let engine = AskEngine(model: model, store: store)

        let (_, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure as? AskFailure == .unsupportedLanguage)
        // The point of pre-flighting: no index was built, so the reader was not
        // made to wait through one to be told the answer can never come.
        #expect(await model.received.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: store.indexURL(for: AskFixture.bookUUID).path,
        ))
    }

    // MARK: - Cancellation

    @Test("cancelling ends the stream without an answer")
    func cancellationEndsWithoutAnAnswer() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(partials: ["Alice foll"], failure: nil, holdsAfterPartials: 1),
        ])
        let engine = AskEngine(model: model, store: store)
        let stream = engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )

        let consumer = Task { await Self.drain(stream) }
        // Wait until the answer is genuinely mid-flight, so this tests
        // cancellation rather than a race with the start of the pipeline.
        await model.waitUntilHolding()
        consumer.cancel()

        let (events, _) = await consumer.value
        #expect(Self.partials(events) == ["Alice foll"])
        #expect(Self.answer(events) == nil)
    }

    // MARK: - The short circuit

    @Test("nothing retrieved answers the sentinel without calling the model")
    func zeroPassagesShortCircuits() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        // The Cheshire Cat first appears in Chapter VI. From the end of
        // Chapter I there is nothing to retrieve, and asking the model would
        // cost several seconds and give it the chance to answer from memory —
        // the one thing the whole design forbids.
        let (events, failure) = await Self.drain(engine.ask(
            question: "Who is the Cheshire Cat?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(answer.notYetRevealed)
        #expect(answer.text == AskAnswerParser.notYetSentinel)
        #expect(await model.received.isEmpty)
    }

    // MARK: - One at a time

    @Test("two questions asked at once are answered one after the other")
    func serialisesRequests() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(partials: ["first"], holdsAfterPartials: 1),
            Turn.answer("Second answer.\nSources: 1"),
        ])
        let engine = AskEngine(model: model, store: store)
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)

        let first = Task {
            await Self.drain(engine.ask(
                question: "What did Alice follow down the hole?",
                source: source, boundary: boundary,
            ))
        }
        await model.waitUntilHolding()

        let second = Task {
            await Self.drain(engine.ask(
                question: "Where did Alice land at the bottom?",
                source: source, boundary: boundary,
            ))
        }
        // The on-device model rejects a second concurrent session outright, so
        // the second question must be waiting rather than racing.
        try await Task.sleep(for: .milliseconds(50))
        #expect(await model.received.count == 1)

        await model.release()
        let (firstEvents, _) = await first.value
        let (secondEvents, _) = await second.value
        #expect(Self.answer(firstEvents) != nil)
        #expect(Self.answer(secondEvents) != nil)
        #expect(await model.received.count == 2)
    }

    // MARK: - Suggestions

    @Test("the chips name the book's own most-mentioned character, bounded")
    func suggestionsComeFromTheIndex() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let engine = AskEngine(model: ScriptedAnswerModel(), store: store)

        let chips = await engine.suggestions(
            source: source, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(chips.count == 2)
        #expect(chips[0] == "Who is Alice?")
        #expect(chips[1] == AskSuggestions.recap)
    }

    @Test("an unbuilt index still gives the sheet two chips to draw")
    func suggestionsFallBack() async throws {
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let engine = AskEngine(model: ScriptedAnswerModel(), store: AskIndexStore(directory: directory))
        let chips = await engine.suggestions(
            source: try AskFixture.source(),
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(chips == [AskSuggestions.fallbackName, AskSuggestions.recap])
    }

    // MARK: - Retry sizing

    @Test("the retry sizes are all of them, then half, then two")
    func attemptSizes() {
        let six = (0 ..< 6).map { _ in PassageRanker.Ranked(
            retrieved: RetrievedPassage(
                passage: Passage(spineIndex: 0, ordinal: 0, start: 0, end: 1, words: 1, text: "x"),
                bm25: 0, isTruncated: false,
            ),
            score: 0,
        ) }
        #expect(AskEngine.attempts(for: six).map(\.count) == [6, 3, 2])
        // Strictly decreasing: a step that is not smaller would fail in exactly
        // the same way, five seconds later.
        #expect(AskEngine.attempts(for: Array(six.prefix(2))).map(\.count) == [2, 1])
        #expect(AskEngine.attempts(for: Array(six.prefix(1))).map(\.count) == [1])
    }
}

/// Shorthand, because every test in here writes one.
private typealias Turn = ScriptedAnswerModel.Turn
