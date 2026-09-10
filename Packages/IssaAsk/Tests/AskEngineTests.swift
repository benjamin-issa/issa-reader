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

    // MARK: - The sampler

    /// The reader-facing promise, in the one place it is enforced: ask the same
    /// question twice and get the same answer, so a reader who doubts an answer
    /// and asks again learns something from the second one.
    @Test("greedy is what ships until a measurement says otherwise")
    func samplingIsOffByDefault() throws {
        #expect(!AskEngine.usesNucleusSampling)
        // And an engine built the way the app builds one — passing nothing —
        // takes the kill switch's answer. The constant on its own says what is
        // written down; this says what the model is handed.
        let directory = try AskFixture.temporaryDirectory()
        defer { AskFixture.remove(directory) }
        let engine = AskEngine(
            model: ScriptedAnswerModel(), store: AskIndexStore(directory: directory),
        )
        let options = engine.generationOptions(
            question: "Who is Alice?",
            bookUUID: AskFixture.bookUUID,
            boundary: ReadingBoundary(spineIndex: 2, charOffset: 100),
        )
        #expect(options.sampling == .greedy)
        #expect(options.temperature == 0)
        #expect(options.maximumResponseTokens == AskPromptBuilder.Budget.responseTokens)
    }

    @Test("the seed is the question, the book and the place in it, and nothing else")
    func theSeedIsTheWholeAsk() {
        let boundary = ReadingBoundary(spineIndex: 2, charOffset: 100)
        func seed(
            _ question: String, _ book: String = "book-a", _ at: ReadingBoundary = boundary,
        ) -> UInt64 {
            AskEngine.seed(question: question, bookUUID: book, boundary: at)
        }
        #expect(seed("Who is Alice?") == seed("Who is Alice?"), "the same ask, twice")
        #expect(seed("Who is Alice?") != seed("Who is Dinah?"))
        #expect(seed("Who is Alice?") != seed("Who is Alice?", "book-b"))
        // Turn back a chapter and the excerpts change, so the answer may too.
        #expect(seed("Who is Alice?") != seed(
            "Who is Alice?", "book-a", ReadingBoundary(spineIndex: 1, charOffset: 100),
        ))
        #expect(seed("Who is Alice?") != seed(
            "Who is Alice?", "book-a", ReadingBoundary(spineIndex: 2, charOffset: 99),
        ))
        // Concatenation without a separator would make these one string.
        #expect(seed("ab", "c") != seed("a", "bc"))
    }

    @Test("asking the same question twice asks the model for the same answer")
    func theSamplerIsSeededPerQuestion() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        // Sampling on, or the two option values being compared are both the
        // greedy default and agree for a reason that has nothing to do with the
        // seed: this test could not fail while the flag was a bare constant.
        let engine = AskEngine(model: model, store: store, usesNucleusSampling: true)
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)

        for _ in 0 ..< 2 {
            _ = await Self.drain(engine.ask(
                question: "Who is Dinah?", source: source, boundary: boundary,
            ))
        }
        let sent = await model.received
        try #require(sent.count == 2)
        // Whatever the sampler is set to, the two asks must agree about it —
        // that is the property, not the particular value.
        #expect(sent[0].options == sent[1].options)
        #expect(sent[0].options.sampling != .greedy, "otherwise the equality proves nothing")
    }

    /// The seed the model is actually handed, end to end.
    ///
    /// Everything above this either reads the constant or compares two values
    /// that were equal anyway. This asks four questions of a sampling engine and
    /// reads what reached the model: the same ask twice must carry the same
    /// seed, a different question or a different place must not, and the seed
    /// must be of the *sanitised* question — the engine sanitises before it
    /// retrieves, so a reader who double-taps the space bar has asked the same
    /// question and must get the same answer.
    @Test("a sampling engine seeds the model from the sanitised ask")
    func aNucleusEngineSeedsFromTheSanitisedAsk() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store, usesNucleusSampling: true)
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterI)
        let later = try AskFixture.endOf(spine: AskFixture.Spine.chapterII)
        let spaced = "Who  is   Dinah?"

        for (question, at) in [
            (spaced, boundary), (spaced, boundary),
            ("Who is the Rabbit?", boundary), (spaced, later),
        ] {
            _ = await Self.drain(engine.ask(question: question, source: source, boundary: at))
        }
        let sent = await model.received
        try #require(sent.count == 4)

        let expected = AskEngine.seed(
            question: QueryTerms.sanitise(spaced),
            bookUUID: source.bookUUID,
            boundary: boundary,
        )
        #expect(sent[0].options.sampling == .nucleus(
            probabilityThreshold: AskEngine.nucleusThreshold, seed: expected,
        ))
        #expect(sent[0].options.temperature == AskEngine.nucleusTemperature)
        // The raw question is what the reader typed, and it is not what was
        // retrieved on; seeding from it would make the double space a different
        // ask from the single one.
        #expect(expected != AskEngine.seed(
            question: spaced, bookUUID: source.bookUUID, boundary: boundary,
        ))

        #expect(sent[0].options == sent[1].options, "the same ask, twice")
        #expect(sent[2].options != sent[0].options, "another question")
        #expect(sent[3].options != sent[0].options, "another place in the book")
    }

    // MARK: - Citations

    @Test("the cited excerpts arrive with the answer, and each is one the model was shown")
    func citedExcerptsComeBackWithTheAnswer() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice follows a white rabbit down a hole.\nSources: 1, 2"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        // Nothing under `Apps/` read `citations` before this: the whole
        // `Sources:` apparatus parsed a line and dropped it.
        #expect(answer.sources.map(\.ordinal) == [1, 2])

        // Not merely non-empty — the excerpt the sheet will show has to be the
        // paragraph the model was actually reading when it cited that number.
        let prompt = try #require(await model.received.first?.prompt)
        for cited in answer.sources {
            #expect(prompt.contains("[\(cited.ordinal)] (Section "))
            #expect(prompt.contains(cited.passage.displayText))
        }
    }

    /// What `AskSourcesRow` picks its three chips with.
    ///
    /// Without a rank the row took the first three citations, which for a recap
    /// — fifteen excerpts, in book order — is the opening of what the reader has
    /// read rather than the evidence the answer leans on.
    @Test("every cited excerpt comes back with the rank the retrieval gave it")
    func citedExcerptsCarryTheirRank() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice follows a white rabbit down a hole.\nSources: 1, 2, 3"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        try #require(answer.sources.count == 3)

        let ranks = answer.sources.map(\.priority)
        #expect(!ranks.contains(nil), "the ranker scored every excerpt in the prompt")
        #expect(Set(ranks).count == ranks.count, "and no two of them hold the same place")
        // The chips the row would draw, in the order the answer cited them.
        #expect(AskSource.best(answer.sources, limit: 2).count == 2)
    }

    @Test("an ordinal the prompt never numbered resolves to nothing")
    func anInventedOrdinalResolvesToNothing() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        // Six excerpts at most, and the model cites the ninth. A 3B model does
        // this often enough that the raw claim is kept and the resolution is
        // what the sheet reads.
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice follows a white rabbit down a hole.\nSources: 1, 99"),
        ])
        let engine = AskEngine(model: model, store: store)

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(answer.citations == [1, 99])
        #expect(answer.sources.map(\.ordinal) == [1])
    }

    /// A tool that shows a fixed excerpt and never has to be called.
    ///
    /// `ScriptedAnswerModel` records the tools it was handed and never invokes
    /// one — nothing deterministic could — so this is how the other half of the
    /// merge gets asserted: that the engine asks each tool what it showed, and
    /// that the answer goes through the protocol rather than through
    /// `SearchBookTool`'s concrete type.
    struct ShowingTool: AskTool {
        let name = "searchBook"
        let toolDescription = "Search the part of the book the reader has already read."
        let callLimit = 2
        let shown: [Int: Passage]

        func passagesShown() async -> [Int: Passage] { shown }
    }

    @Test("an excerpt the search tool showed is resolvable too, not only the prompt's")
    func toolExcerptsResolveAsWell() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        // Seven, which is past anything the prompt itself numbers: the tool's
        // excerpts continue the prompt's numbering, and before the tool retained
        // anything *no* citation in its range could be resolved at all.
        let found = Passage(
            spineIndex: 3, ordinal: 0, start: 100, end: 146, words: 9,
            text: "a White Rabbit with pink eyes ran close by her",
        )
        let model = ScriptedAnswerModel(turns: [
            .answer("Alice followed a white rabbit.\nSources: 7"),
        ])
        let engine = AskEngine(
            model: model, store: store, tools: [ShowingTool(shown: [7: found])],
        )

        let (events, failure) = await Self.drain(engine.ask(
            question: "What did Alice follow down the hole?", source: source,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(answer.sources.map(\.ordinal) == [7])
        #expect(answer.sources.first?.passage == found)
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
        // Nothing was cited, so nothing is offered: excerpts under "the story
        // hasn't revealed that yet" would be proof of an absence.
        #expect(answer.sources.isEmpty)
        #expect(answer.origin == .withheld)
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
        // The refusal builds a fresh answer, so the generated one's excerpts go
        // with its prose. "Returns the sentinel but keeps the old sources" would
        // put the evidence for an answer the reader is not being given directly
        // under the sentence saying they are not being given it.
        #expect(answer.sources.isEmpty, "and shows nothing it was going to rest on")
        #expect(answer.origin == .withheld)
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
            ("Aldric dies. Ryn escapes.", "What happens next?", ["aldric", "ryn"]),
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
            ("The note said: Aldric is alive.", "What did the note say?", ["aldric"]),
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
        "Ryn had grown up on the streets of Ardmoor, in the rain and the smoke, and she had "
            + "learned very early that a girl who trusted anybody at all did not last long there.",
        "Her brother, Dask, had trained her to trust nobody, and then he had left her alone in "
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

        // The question that answered "Sorrel" on the real book.
        let (events, failure) = await Self.drain(engine.ask(
            question: "What is the name of Ryn's brother?", source: source, boundary: boundary,
        ))
        #expect(failure == nil)
        let answer = try #require(Self.answer(events))
        #expect(answer.text == "Ryn's brother is Dask.")
        #expect(!answer.notYetRevealed)
        #expect(!answer.citations.isEmpty)
        // The best citation in the app, and it used to be thrown away: the
        // extractor cites an index into the very array retrieval handed it, so
        // the excerpt shown is provably the sentence the name was read out of.
        let cited = try #require(answer.sources.first)
        #expect(cited.ordinal == answer.citations.first)
        #expect(cited.passage.displayText.contains("Dask"))
        // And it carries its place in the evidence, like a generated answer's
        // sources do — this path resolves against its own array, not the
        // prompt's, and used to hand the row nothing to choose with.
        #expect(cited.priority != nil)
        // And nothing generated it, so the sheet must not claim a model did.
        #expect(answer.origin == .book)
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
            "Ryn's brother, Aldric, had said much the same thing to her once, in the same "
                + "flat voice, on an evening when the ash was falling thickly over the market.",
        )
        let (store, source, boundary, directory) = try AskFixture.syntheticStore(
            chapters: [chapter],
        )
        defer { AskFixture.remove(directory) }
        let model = ScriptedAnswerModel()
        let engine = AskEngine(model: model, store: store)

        _ = await Self.drain(engine.ask(
            question: "Who is Ryn's brother?", source: source, boundary: boundary,
        ))
        // Two brothers, or a pattern that matched something it should not have.
        // Either way the model reads it, with both sentences in the prompt.
        //
        // The *answer* is the sentinel, which is not what it looks like: the
        // scripted reply opens with "Alice", who does not exist in this
        // four-paragraph book, so the answer-side guard refuses it. What this
        // test asserts is what the model was handed, which is unaffected.
        let sent = try #require(await model.received.first)
        #expect(sent.prompt.contains("Dask"))
        #expect(sent.prompt.contains("Aldric"))
    }

    // MARK: - Evidence in the prompt

    @Test("an identity question sends sentences, not paragraphs")
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
        // Sentence windows rather than whole paragraphs: the measured prompt on
        // the real book was 45% smaller for the same question.
        //
        // Per excerpt, not in total, because that is the claim. A passage chunk
        // is ninety words and a sentence window is one sentence or two, so the
        // shape is what says the retrieval is working — and a bound on the
        // total moves every time the count is tuned. The 6,000 characters that
        // stood here had four times the room to spare at six excerpts and a
        // third of it at fifteen, which is a test on its way to failing for a
        // reason that has nothing to do with what it asserts.
        #expect(sent.prompt.count / excerpts < 400)
    }

    @Test("the instructions say what to do with a passing mention")
    func instructionsCoverPassingMentions() {
        // "Who is Ryn?" was answered with a biography stitched out of the nouns
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

    @Test("the chips name the book's own most-mentioned characters, bounded")
    func suggestionsComeFromTheIndex() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let engine = AskEngine(model: ScriptedAnswerModel(), store: store)

        let chips = await engine.suggestions(
            source: source, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        #expect(chips.count == 6)
        // The two that shipped, in the order they shipped in.
        #expect(chips[0] == "Who is Alice?")
        #expect(chips[1] == AskSuggestions.recap)
        // Alice's own index also holds "Alice soon began" and "David Widger" as
        // people — the first an `NLTagger` misfire, the second the Gutenberg
        // credits — and neither may reach a chip. The second name is the cat.
        #expect(chips.contains("Who is Dinah?"))
        #expect(chips.allSatisfy { !$0.contains("Widger") && !$0.contains("soon began") })
    }

    /// Non-fiction, for the same reason `AskFixture.franklin` exists at all: the
    /// index's top names on a memoir are the people the author writes about,
    /// and a chip that offered "Who is Benjamin Franklin?" to a reader of
    /// Franklin's own autobiography would be the wrong two names.
    @Test("the chips work on a memoir as well as on a novel")
    func suggestionsOnNonFiction() async throws {
        let (store, source, directory) = try await AskFixture.franklin.preparedStore()
        defer { AskFixture.remove(directory) }
        let engine = AskEngine(model: ScriptedAnswerModel(), store: store)

        let chips = await engine.suggestions(
            source: source, boundary: try AskFixture.franklin.endOf(spine: 6),
        )
        #expect(chips.count == 6)
        #expect(chips[0] == "Who is Keimer?")
        #expect(chips[1] == AskSuggestions.recap)
    }

    @Test("an unbuilt index still gives the sheet chips to draw")
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

    /// A ranked passage at a place in the book, with a rank of its own.
    static func ranked(ordinal: Int, priority: Int) -> PassageRanker.Ranked {
        PassageRanker.Ranked(
            retrieved: RetrievedPassage(
                passage: Passage(
                    spineIndex: 0, ordinal: ordinal, start: ordinal * 100,
                    end: ordinal * 100 + 1, words: 1, text: "x",
                ),
                bm25: 0, isTruncated: false,
            ),
            priority: priority,
        )
    }

    @Test("the retry sizes are all of them, then half, then two")
    func attemptSizes() {
        let six = (0 ..< 6).map { Self.ranked(ordinal: $0, priority: $0) }
        #expect(AskEngine.attempts(for: six).map(\.count) == [6, 3, 2])
        // Strictly decreasing: a step that is not smaller would fail in exactly
        // the same way, five seconds later.
        #expect(AskEngine.attempts(for: Array(six.prefix(2))).map(\.count) == [2, 1])
        #expect(AskEngine.attempts(for: Array(six.prefix(1))).map(\.count) == [1])
    }

    @Test("each retry keeps the best of them, not the earliest")
    func attemptsKeepTheBest() throws {
        // Book order in, worst first — which is what a recap looks like, and
        // what the reader's own question is least interested in.
        let six = (0 ..< 6).map { Self.ranked(ordinal: $0, priority: 5 - $0) }
        let attempts = AskEngine.attempts(for: six)
        try #require(attempts.count == 3)

        // This took a `prefix`, so the retry that was meant to save the answer
        // threw away the end of what the reader had read and kept the opening.
        #expect(attempts[1].map(\.passage.ordinal) == [3, 4, 5])
        #expect(attempts[2].map(\.passage.ordinal) == [4, 5])
        // Still reading order, and still nested: each attempt is a subset of
        // the one before it, or the prompt does not shrink so much as change.
        for (smaller, larger) in zip(attempts.dropFirst(), attempts) {
            #expect(smaller.map(\.passage.ordinal) == smaller.map(\.passage.ordinal).sorted())
            #expect(Set(smaller).isSubset(of: Set(larger)))
        }
    }
}

/// Shorthand, because every test in here writes one.
private typealias Turn = ScriptedAnswerModel.Turn
