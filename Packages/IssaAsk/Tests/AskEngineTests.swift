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

        let seen = Collected()
        let consumer = Task {
            do {
                for try await event in stream { await seen.append(event) }
            } catch {}
        }
        // Wait until the answer is genuinely mid-flight, so this tests
        // cancellation rather than a race with the start of the pipeline. Both
        // waits are needed: the model holding says the partial was *sent*, and
        // the second says it was *received* — cancelling a task mid-iteration
        // discards whatever is still sitting in the stream's buffer, which made
        // this fail about half the time for reasons that had nothing to do with
        // cancellation.
        await model.waitUntilHolding()
        await seen.waitForAPartial()
        consumer.cancel()
        _ = await consumer.value

        #expect(Self.partials(await seen.events) == ["Alice foll"])
        #expect(Self.answer(await seen.events) == nil)
    }

    /// Events as the consumer actually saw them, and a way to wait for the
    /// first one to land.
    actor Collected {
        var events: [AskEvent] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func append(_ event: AskEvent) {
            events.append(event)
            guard case .partial = event else { return }
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func waitForAPartial() async {
            guard !events.contains(where: { if case .partial = $0 { true } else { false } })
            else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
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

    // MARK: - The answer-side guard

    /// The twin of the short circuit above, and the case it cannot reach.
    ///
    /// Here the *question* is entirely met — Alice and the rabbit are both in
    /// Chapter I — so retrieval is non-empty and the model is called. The model
    /// then answers with a character the reader has not met, which is exactly
    /// what the live model did when the retrieval was non-empty. Nothing before
    /// this point can catch it: the passages were bounded correctly, and the
    /// spoiler came out of the model's memory rather than out of the book.
    @Test("an answer naming somebody the book has not introduced is refused")
    func unmetNameInTheAnswerIsRefused() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice followed a white rabbit down the hole. She was later guided by the Cheshire Cat.\nSources: 1"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        // The model was asked — this is not the short circuit.
        #expect(await model.received.count == 1)
        let answer = try #require(Self.answer(events))
        #expect(answer.notYetRevealed)
        #expect(answer.text == AskAnswerParser.notYetSentinel)
        #expect(answer.citations.isEmpty, "a refused answer cites nothing")
    }

    /// The same answer past the chapter that introduces the Cat is ordinary
    /// prose. Without this the guard could be passing by refusing everything.
    @Test("the same answer stands once the book has introduced the name")
    func metNameInTheAnswerIsKept() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice followed a white rabbit down the hole. She was later guided by the Cheshire Cat.\nSources: 1"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(!answer.notYetRevealed)
        #expect(answer.text.contains("Cheshire"))
    }

    @Test(
        "a capitalised word is a name unless the sentence had to capitalise it",
        arguments: [
            // The deliberate over-catch. "Rome" is a place, not a person, and
            // nothing here can tell it from "Alice". It does not have to: the
            // probe arbitrates, and "Rome" is in *Alice* Chapter II — "London
            // is the capital of Paris, and Paris is the capital of Rome" — so
            // it is cleared from there onwards and refused before it.
            ("Rome fell.", "What happens next?", ["rome"]),
            // The bug. Both spoilers opened a sentence, so both went through.
            ("Kelsier dies. Vin escapes.", "What happens next?", ["kelsier", "vin"]),
            // A headline spoiler is very often the first word of the answer.
            ("Bilbo found the ring in the dark.", "What happened in the tunnel?", ["bilbo"]),
            // `Mr.` used to end a sentence, which exempted every name that
            // followed an honorific.
            ("She met Mr. Darcy at the ball.", "Who did she meet?", ["darcy"]),
            // Both "Alice"s open sentences and "Alice" is in the question
            // besides; "the" and "who" are function words. What is left is the
            // pair a reader could be spoiled by.
            (
                "Alice met the Duchess, who knew Bilbo. Alice waved.",
                "Who is Alice?", ["bilbo", "duchess"]
            ),
            // A colon introduces a continuation, not a sentence.
            ("The note said: Kelsier is alive.", "What did the note say?", ["kelsier"]),
            // The row that earns the list: four sentences, four openers, and
            // not one of them a person.
            (
                "The rabbit ran. She followed it. There was a door. "
                    + "Then everything went dark.",
                "What happened?", []
            ),
            // The honest worst case. "Cooks" is a plural noun opening a
            // sentence, and it costs a refusal on a book that never uses the
            // word. A test that hid this would be a bad test.
            ("Cooks use pepper.", "Why is the soup peppery?", ["cooks"]),
        ],
    )
    func capitalisedWordsAreNamesUnlessGrammarCapitalisedThem(
        answer: String, question: String, expected: [String],
    ) {
        #expect(AskEngine.unvettedNames(in: answer, question: question) == expected)
    }

    @Test("a sentence-opening name the book has used is answered, not refused")
    func aMetNameOpeningASentenceIsNotRefused() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        // "Alice" is not in the question, and it opens both sentences — so the
        // guard offers it to the probe, which finds her on page one. Without
        // this the guard could pass every test above by refusing everything.
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice followed the rabbit. Alice fell down the hole.\nSources: 1"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What happened at the start?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(!answer.notYetRevealed)
        #expect(answer.text.contains("Alice"))
        // And the guard really was offered her, rather than skipping the check.
        #expect(AskEngine.unvettedNames(
            in: answer.text, question: "What happened at the start?",
        ) == ["alice"])
    }

    // MARK: - The kinship fast path

    /// The sentences the measured failure turned on, in a book of four
    /// paragraphs rather than three hundred thousand words.
    static let kinshipChapter = [
        "Vin had grown up on the streets of Luthadel, in the ash and the mist, and she had "
            + "learned very early that a girl who trusted anybody at all did not last long there.",
        "Her brother, Reen, had trained her to trust nobody, and then he had left her alone in "
            + "that city without so much as a word of warning about what was coming for them.",
        "The crew met in the shop behind the market, where the windows were shuttered against "
            + "the ash and somebody had left a lamp burning on the counter all night long.",
        "She thought about the mists a great deal in those days, and about the way the ash fell "
            + "on the city every evening without ever once seeming to bury it completely.",
    ]

    @Test("a relationship the book states is answered without calling the model")
    func kinshipFastPathAnswersOutright() async throws {
        let (store, source, boundary, directory) = try AskFixture.syntheticStore(
            chapters: [Self.kinshipChapter],
        )
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        // The question that answered "Quellion" on the real book.
        let (events, failure) = await Self.drain(engine.ask(
            question: "What is the name of Vin's brother?", source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(answer.text == "Vin's brother is Reen.")
        #expect(!answer.notYetRevealed)
        #expect(!answer.citations.isEmpty)
        // Nothing to think about, so nothing to wait for: no model call, and no
        // `.thinking` phase promising one.
        #expect(await model.received.isEmpty)
        #expect(!events.contains(.phase(.thinking)))
        #expect(events.contains(.phase(.retrieving)))
    }

    @Test("two candidate names go to the model, with both sentences in front of it")
    func twoNamesFallThroughToTheModel() async throws {
        var chapter = Self.kinshipChapter
        chapter.append(
            "Vin's brother, Kelsier, had said much the same thing to her once, in the same "
                + "flat voice, on an evening when the ash was falling thickly over the market.",
        )
        let (store, source, boundary, directory) = try AskFixture.syntheticStore(
            chapters: [chapter],
        )
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        _ = await Self.drain(engine.ask(
            question: "Who is Vin's brother?", source: source, boundary: boundary,
        ))
        // Two brothers, or a pattern that matched something it should not have.
        // Either way the model reads it, with both sentences in the prompt.
        //
        // The *answer* is the sentinel, which is not what it looks like: the
        // scripted reply opens with "Alice", who does not exist in this
        // four-paragraph book, so the answer-side guard refuses it. What this
        // test asserts is what the model was handed, which is unaffected.
        let sent = try #require(await model.received.first)
        #expect(sent.prompt.contains("Reen"))
        #expect(sent.prompt.contains("Kelsier"))
    }

    // MARK: - Evidence in the prompt

    @Test("an identity question sends sentences, not paragraphs, and no more than twelve")
    func identityPromptIsSentenceSized() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        _ = await Self.drain(engine.ask(
            question: "Who is Alice?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        ))
        let sent = try #require(await model.received.first)
        let excerpts = sent.prompt.components(separatedBy: "] (Section ").count - 1
        #expect(excerpts > 0)
        #expect(excerpts <= EvidenceFinder.Limits.identityExcerpts)
        // Sentence windows rather than six whole paragraphs: the measured
        // prompt on the real book was 45% smaller for the same question.
        #expect(sent.prompt.count < 6_000)
    }

    @Test("the instructions say what to do with a passing mention")
    func instructionsCoverPassingMentions() {
        // "Who is Vin?" was answered with a biography stitched out of the nouns
        // standing near her name. Retrieval is the fix; this is the belt.
        #expect(AskPromptBuilder.instructions.contains("only mention a person in passing"))
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
        #expect(await model.peakConcurrency == 1)
    }

    @Test("two engines sharing a turnstile answer one after the other")
    func twoEnginesShareOneTurn() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(partials: ["first"], holdsAfterPartials: 1),
            Turn.answer("Second answer.\nSources: 1"),
        ])
        // Two engines is what the app has: `AskCoordinator` builds a fresh one
        // per question, so the turnstile that used to live on the engine
        // serialised nothing at all and two books gave two concurrent
        // generations. There is one model on the device; the turn is the
        // process's, not the engine's.
        let turnstile = AskTurnstile()
        let first = AskEngine(model: model, store: store, turnstile: turnstile)
        let second = AskEngine(model: model, store: store, turnstile: turnstile)
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)

        let firstTask = Task {
            await Self.drain(first.ask(
                question: "What did Alice follow down the hole?",
                source: source, boundary: boundary,
            ))
        }
        await model.waitUntilHolding()

        let secondTask = Task {
            await Self.drain(second.ask(
                question: "Where did Alice land at the bottom?",
                source: source, boundary: boundary,
            ))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await model.received.count == 1)

        await model.release()
        _ = await firstTask.value
        _ = await secondTask.value
        #expect(await model.received.count == 2)
        // The assertion that says the thing rather than inferring it from when
        // the sleep happened to land.
        #expect(await model.peakConcurrency == 1)
    }

    @Test("an answer that never reaches the model does not wait for one that has")
    func theShortCircuitDoesNotQueue() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            Turn(partials: ["first"], holdsAfterPartials: 1),
        ])
        let turnstile = AskTurnstile()
        let asking = AskEngine(model: model, store: store, turnstile: turnstile)
        let refusing = AskEngine(model: model, store: store, turnstile: turnstile)
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)

        let held = Task {
            await Self.drain(asking.ask(
                question: "What did Alice follow down the hole?",
                source: source, boundary: boundary,
            ))
        }
        await model.waitUntilHolding()

        // The Cheshire Cat is ten chapters ahead, so this is answered in SQL
        // and never calls the model. With the turn taken around the whole
        // question it waited behind the held generation anyway — a question
        // answered in two milliseconds, sitting out somebody else's twenty
        // seconds.
        let (events, failure) = await Self.drain(refusing.ask(
            question: "Who is the Cheshire Cat?", source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        #expect(Self.answer(events)?.notYetRevealed == true)
        #expect(await model.received.count == 1)

        await model.release()
        _ = await held.value
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
