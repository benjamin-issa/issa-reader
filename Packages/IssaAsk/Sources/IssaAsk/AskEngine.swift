import Foundation
import IssaCore

/// One question, one answer, bounded by where the reader has got to.
///
/// The engine owns the order of operations, and the order is the feature:
/// prepare the index, search *before the boundary*, rank, pack what fits, and
/// only then call the model. Nothing here reads the book directly; retrieval is
/// a SQL clause in `AskIndexStore` that cannot be persuaded to return a passage
/// from later in the book, and this actor's job is to never route around it.
///
/// An `actor` because the index handle and the tools' per-generation state need
/// one owner. Serialising the model is *not* one of its jobs and never could
/// be: `AskCoordinator` builds a fresh engine per question, so the turnstile
/// that used to live here served an audience of one, and two books meant two
/// concurrent generations. It is `AskTurnstile` now — one per process, passed
/// in.
///
/// Those two generations do not fail with `concurrentRequests`, whatever this
/// comment used to say. That error is per session — "a second prompt while it's
/// still responding to the first one" — and `SystemAnswerModel.answer` builds a
/// fresh `LanguageModelSession` for every generation, so two questions have two
/// sessions. What they run into is `rateLimited`, the process-wide one. Both
/// become `.busy`, so the reader's symptom and the fix are unchanged; the
/// reason is not.
public actor AskEngine {
    private let model: any AnswerModel
    /// Held publicly because the app also deletes indexes from it when a
    /// download goes, and there must be exactly one of these per process:
    /// two would open the same SQLite file twice.
    public nonisolated let store: AskIndexStore
    private let tools: [any AskTool]
    private let turnstile: AskTurnstile

    /// - Parameter tools: the `searchBook` tool, or nothing.
    ///
    ///   It is a constructor argument rather than a constant so it can be
    ///   switched off with one flag: the 3B model is only moderately reliable at
    ///   deciding when to search, and every round trip is another three to six
    ///   seconds on a phone. If the measurement goes against it, this is the
    ///   line that changes — and the engine is otherwise identical with and
    ///   without it, which is what makes the comparison worth anything.
    /// - Parameter turnstile: the process's one turn at the on-device model.
    ///   Defaulted so a test that only cares about one question writes nothing,
    ///   and so an engine on its own behaves exactly as it did; the app passes
    ///   the same one to every engine it builds, which is the whole point of
    ///   the type.
    public init(
        model: any AnswerModel,
        store: AskIndexStore,
        tools: [any AskTool] = [],
        turnstile: AskTurnstile = AskTurnstile(),
    ) {
        self.model = model
        self.store = store
        self.tools = tools
        self.turnstile = turnstile
    }

    // MARK: - Index

    /// Builds this book's index if it is missing or stale.
    ///
    /// Separate from `ask` so the sheet can start it the moment it opens, while
    /// the reader is still typing: on a long illustrated book the build is the
    /// larger half of the first question's latency.
    @discardableResult
    public func prepareIndex(
        source: BookSource,
        progress: (@Sendable (AskPhase) -> Void)? = nil,
    ) async throws -> Bool {
        do {
            return try await store.prepare(source: source, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Never the title, never the question — a log is exported by the
            // reader and pasted into an email.
            IssaLog.error("ask index failed", ["kind": String(describing: type(of: error))])
            throw AskFailure.indexFailed
        }
    }

    /// Warms the model while the reader looks at the chips.
    ///
    /// Skipped rather than queued when a question already holds the turn: what
    /// a prewarm would load, that question has loaded already.
    public func prewarm() async {
        await turnstile.ifFree { await self.model.prewarm() }
    }

    /// The chips under the question field.
    ///
    /// Falls back to the generic pair when the index is not built yet, so the
    /// sheet has something to draw immediately rather than empty capsules that
    /// fill in eight seconds later.
    public func suggestions(source: BookSource, boundary: ReadingBoundary) async -> [String] {
        guard await store.isPrepared(source: source),
              let names = try? await store.topNames(
                  in: source.bookUUID, before: boundary,
                  limit: AskSuggestions.namesWanted,
              )
        else { return AskSuggestions.chips(topNames: []) }
        return AskSuggestions.chips(topNames: names)
    }

    // MARK: - Asking

    /// Everything that happens between the question and the answer.
    ///
    /// A stream rather than an awaited value because the phases and the partial
    /// text are the difference between "seven seconds of spinner" and a sheet
    /// that is visibly working; and because the reader may close the sheet and
    /// get a notification, which needs the job to outlive the view either way.
    ///
    /// Cancelling the consuming task cancels the whole pipeline — the index
    /// build between chapters, the retrieval, and the generation between
    /// snapshots.
    public nonisolated func ask(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
    ) -> AsyncThrowingStream<AskEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.perform(
                    question: question, source: source, boundary: boundary, into: continuation,
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func perform(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async {
        do {
            try await answer(
                question: question, source: source, boundary: boundary, into: continuation,
            )
            continuation.finish()
        } catch is CancellationError {
            // Not a failure the reader is told about: they asked for it. The
            // stream ends without `.answered`, which is what the sheet reads as
            // "cancelled".
            continuation.finish()
        } catch {
            continuation.finish(throwing: Self.failure(for: error))
        }
    }

    private func answer(
        question: String,
        source: BookSource,
        boundary: ReadingBoundary,
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async throws {
        try Task.checkCancellation()
        // Before anything expensive: a book the model has no language for will
        // fail at the last step otherwise, after a full index build.
        guard model.supportsLanguage(source.language) else { throw AskFailure.unsupportedLanguage }

        try await prepareIndex(source: source) { phase in continuation.yield(.phase(phase)) }

        try Task.checkCancellation()
        continuation.yield(.phase(.retrieving))
        let retriever = AskRetriever(
            store: store, bookUUID: source.bookUUID, boundary: boundary,
            allowsFastPath: Self.usesKinshipFastPath,
        )
        let retrieval = try await retriever.retrieve(question: question)
        let sanitised = QueryTerms.sanitise(question)

        switch retrieval {
        // Two ways the answer is "not yet", and both are settled here rather
        // than by the model. Nothing retrieved at all is the obvious one. The
        // other is a question naming somebody the book has not introduced:
        // retrieval happily returns six passages about the *other* words in the
        // question, and the model — asked "Who is the Cheshire Cat?" from the
        // end of Chapter I, handed excerpts containing no cat but Dinah —
        // answered from memory, ten chapters ahead of the reader. Instructions
        // that forbade it twice did not stop it; this does.
        case let .notYet(unmet):
            IssaLog.info("ask answered as not yet revealed", ["unmet": String(unmet.count)])
            // No sources, and never any: nothing was cited, and offering
            // excerpts under "the story hasn't revealed that yet" would be
            // showing the reader proof of an absence.
            continuation.yield(.answered(AskAnswer(
                text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
                origin: .withheld,
            )))

        // The book states the answer in so many words, so there is nothing to
        // think about and no `.thinking` phase to show. It is still vetted:
        // the sentence was assembled from the book, but the guard is cheap and
        // an unvetted path is a path somebody will later route around.
        //
        // The evidence is bound rather than dropped, and this is the best
        // citation the feature has: `KinshipExtractor` cites `evidenceIndex + 1`
        // into the very array `EvidenceFinder.ranked` preserved 1:1, so the
        // excerpt shown is provably the sentence the answer was lifted from —
        // which no generated answer can claim.
        case let .answered(answer, evidence):
            continuation.yield(.answered(
                try await vetted(
                    AskAnswerParser.resolving(answer, among: Self.numbered(evidence.map(\.passage))),
                    question: sanitised,
                    bookUUID: source.bookUUID, boundary: boundary,
                ),
            ))

        case let .evidence(ranked, _):
            try Task.checkCancellation()
            continuation.yield(.phase(.thinking))
            let generated = try await generate(
                question: sanitised, ranked: ranked,
                options: Self.generationOptions(
                    question: sanitised, bookUUID: source.bookUUID, boundary: boundary,
                ),
                into: continuation,
            )
            try Task.checkCancellation()
            continuation.yield(.answered(
                try await vetted(
                    generated, question: sanitised,
                    bookUUID: source.bookUUID, boundary: boundary,
                ),
            ))
        }
    }

    /// Whether "Who is X's brother?" may be answered from the book's own
    /// sentence without a model call.
    ///
    /// A constant rather than a constructor argument because it is a kill
    /// switch, not a choice: if the table ever answers something it should have
    /// declined, this is the one line that turns it off, and every question
    /// goes back to the model with the same sentences in front of it.
    static let usesKinshipFastPath = true

    /// Whether the model may sample rather than take the likeliest token.
    ///
    /// A kill switch in the same spirit as the one above, and false until a
    /// measurement says otherwise. Greedy is what makes two identical asks
    /// identical, so this is not a knob to turn on a hunch — it is turned on by
    /// a scored replication or not at all. `seed` below is what keeps the
    /// promise when it is turned on.
    static let usesNucleusSampling = false
    static let nucleusThreshold = 0.9
    static let nucleusTemperature = 0.3

    /// The seed that makes a sampled answer repeatable.
    ///
    /// The question, the book, and the place in it — exactly the three things
    /// that make two asks "the same ask" to a reader. Turn back a chapter and
    /// ask again and the seed changes, which is right, because the excerpts
    /// changed too.
    ///
    /// `spineIndex` and `charOffset` and nothing else off the boundary: how the
    /// boundary came to be fixed is not where it is, and two boundaries at the
    /// same offset retrieve the same excerpts.
    ///
    /// Separated by a byte that appears in no question and no uuid, or
    /// ("ab", "c") and ("a", "bc") would seed the same.
    static func seed(
        question: String, bookUUID: String, boundary: ReadingBoundary,
    ) -> UInt64 {
        FNV1a.hash(
            "\(question)\u{1}\(bookUUID)\u{1}\(boundary.spineIndex)\u{1}\(boundary.charOffset)",
        )
    }

    /// What the model is asked to do with its sampler, for this one question.
    static func generationOptions(
        question: String, bookUUID: String, boundary: ReadingBoundary,
    ) -> AskGenerationOptions {
        guard usesNucleusSampling else {
            return AskGenerationOptions(
                maximumResponseTokens: AskPromptBuilder.Budget.responseTokens,
            )
        }
        return AskGenerationOptions(
            maximumResponseTokens: AskPromptBuilder.Budget.responseTokens,
            temperature: nucleusTemperature,
            sampling: .nucleus(
                probabilityThreshold: nucleusThreshold,
                seed: seed(question: question, bookUUID: bookUUID, boundary: boundary),
            ),
        )
    }

    /// Excerpts by the ordinal they were numbered with, one-based.
    ///
    /// The one place the numbering convention is written down: the prompt
    /// builder numbers its passages from 1, `KinshipExtractor` cites into its
    /// evidence array the same way, and a citation is only resolvable because
    /// both count from the same place.
    static func numbered(_ passages: [Passage]) -> [Int: Passage] {
        Dictionary(uniqueKeysWithValues: passages.enumerated().map { ($0.offset + 1, $0.element) })
    }

    // MARK: - Vetting the answer

    /// The output side of the question-side guard above.
    ///
    /// The question-side guard catches "Who is the Cheshire Cat?" because the
    /// name is in the question. It cannot catch the other half of the same
    /// defect: a question whose own words are all met — "What does Alice meet in
    /// the wood?" — retrieves six perfectly bounded passages, and the model
    /// answers with a character from ten chapters ahead anyway, because it has
    /// read the book. Retrieval was never the leak; the model's memory is. So
    /// the answer is held to the same test the question is: every name in it
    /// must be a name the book has already used.
    ///
    /// Words already in the question are exempt, because the question-side
    /// guard has ruled on those. A word that merely begins a sentence is exempt
    /// only when it is a function word — see `unvettedNames`.
    ///
    /// The sources are deliberately **not** filtered. Every one of them is book
    /// text the reader has already passed: an excerpt exists only because
    /// `AskIndexStore` returned it from a query bounded by `boundary`, so a
    /// second check here would be a check on something true by construction —
    /// and one that could only ever go wrong by dropping honest evidence.
    private func vetted(
        _ answer: AskAnswer, question: String, bookUUID: String, boundary: ReadingBoundary,
    ) async throws -> AskAnswer {
        guard !answer.notYetRevealed else { return answer }
        let candidates = Self.unvettedNames(in: answer.text, question: question)
        guard !candidates.isEmpty else { return answer }
        let unmet = try await store.unmetWords(candidates, in: bookUUID, before: boundary)
        guard !unmet.isEmpty else { return answer }

        // Never the words themselves: an unmet name is a spoiler, and the log
        // is exported by the reader and pasted into an email.
        IssaLog.info("ask answered as not yet revealed", ["unmetInAnswer": String(unmet.count)])
        // A fresh answer, so the refused one's sources go with its prose. The
        // reader is being told the story has not revealed this; excerpts under
        // that sentence would be the evidence for an answer they are not being
        // given.
        return AskAnswer(
            text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
            origin: .withheld,
        )
    }

    /// Capitalised words in an answer that the question did not already ask
    /// about and that a sentence did not have to capitalise.
    ///
    /// Deliberately the same crude test as `QueryTerms.nameCandidates`, and for
    /// the same reason: the names readers get spoiled by are invented ones no
    /// general-purpose tagger knows. Over-catching costs a "the story hasn't
    /// revealed that yet" for an answer that was fine; under-catching costs the
    /// one promise the feature makes.
    ///
    /// This once exempted **every** word that opened a sentence, on the true
    /// premise that "Alice went home" and "Rome fell" cannot be told apart
    /// without a tagger. The conclusion drawn from it was wrong. Every sentence
    /// starts with a capital, so exempting them all exempted the spoiler:
    /// `unvettedNames(in: "Kelsier dies. Vin escapes.", question: "What happens
    /// next?")` returned `[]`, and both names went to the reader. So did
    /// "Bilbo found the ring in the dark." — a headline spoiler is very often
    /// the first word.
    ///
    /// The extractor does not need to be right, it needs to be generous, and
    /// `AskIndexStore.unmetWords` arbitrates per book: over-catching is only
    /// expensive when the over-caught word is absent from the part the reader
    /// has read, and that is exactly the question the index answers.
    ///
    /// **Not `NLTagger`.** The only safe use of it here is as a positive
    /// exemption — "the tagger says this is a place" — which opens a hole
    /// precisely where place names are the spoiler: "Mordor lies to the east."
    /// Using its silence to exempt is worse still, because invented names are
    /// what it misses and invented names are what readers get spoiled by.
    static func unvettedNames(in answer: String, question: String) -> [String] {
        // Possessive-stripped on both sides, so "Reen's" in the answer is
        // checked against the index as `reen` — the word the book actually
        // contains — and a name the question already asked about is still
        // recognised when the answer inflects it.
        let asked = Set(QueryTerms.tokens(in: question).map(QueryTerms.strippingPossessive))
        var candidates: Set<String> = []
        // The first word of the answer opens a sentence like any other.
        var opensSentence = true

        for word in answer.split(whereSeparator: \.isWhitespace) {
            // Closing marks first: `said "Hello."` ends a sentence, and its
            // last character is a quotation mark.
            let closed = String(word).trimmingCharacters(in: Self.closingMarks)
            let bare = String(word).trimmingCharacters(in: CharacterSet.letters.inverted)
            let endsSentence = Self.endsSentence(closed, bare: bare)
            defer { opensSentence = endsSentence }

            guard let initial = bare.first, initial.isUppercase, bare.count > 2,
                  !QueryTerms.capitalisedNonNames.contains(bare.lowercased())
            else { continue }
            // The exemption is conditional. A word that opens a sentence is
            // exempt only when it is a closed-class function word, because
            // those are the words a sentence capitalises for grammar rather
            // than for a person. No special case for the first word of the
            // answer: "Kelsier dies." puts the spoiler there.
            if opensSentence, QueryTerms.sentenceOpeners.contains(bare.lowercased()) { continue }
            for token in QueryTerms.tokens(in: bare).map(QueryTerms.strippingPossessive)
                where token.count > 2 && !asked.contains(token) {
                candidates.insert(token)
            }
        }
        return candidates.sorted()
    }

    /// Whether this word closes a sentence, so the next one opens one.
    ///
    /// An honorific does not, even though it ends in a full stop. "She met Mr.
    /// Darcy at the ball." exempted Darcy outright: `Mr.` looked like the end
    /// of a sentence, so every name after an honorific opened one. Reusing
    /// `NameFinder.honorifics` keeps one list — the same one that stops "Mr.
    /// Rabbit" and "Rabbit" being counted as two people. A sentence that
    /// genuinely ends on an honorific loses the exemption for the word after
    /// it, which is the conservative direction.
    static func endsSentence(_ closed: String, bare: String) -> Bool {
        guard let last = closed.last, sentenceEnders.contains(last) else { return false }
        return !NameFinder.honorifics.contains(bare.lowercased())
    }

    /// No colon and no semicolon: both introduce a continuation rather than
    /// close a sentence, and while they were here `The note said: Kelsier is
    /// alive.` exempted the name the note was about.
    static let sentenceEnders: Set<Character> = [".", "!", "?"]
    /// Quotation marks and brackets, which sit outside the full stop.
    static let closingMarks = CharacterSet(charactersIn: "\"'”’)]}»›")

    // MARK: - Generation

    /// Streams an answer, shrinking the prompt if the window says no.
    ///
    /// The retries are the plan's: all the passages, then half, then two. A
    /// 4,096-token window measured with the model's own tokeniser should not
    /// overflow at all, but `tokenCount` is not free on a phone and the builder
    /// estimates first — so the overflow that does happen is the estimate being
    /// wrong, and halving is the cheapest way to be certainly right.
    ///
    /// The turn is taken here rather than around the whole question, and it
    /// covers all three attempts. Around the question it queued work that never
    /// reaches the model at all: `.notYet` and the kinship fast path answer
    /// from SQL in milliseconds and still waited behind another book's
    /// twenty-second generation. Re-acquiring per attempt would be worse than
    /// either — another question could take the turn in the middle of a retry.
    private func generate(
        question: String,
        ranked: [PassageRanker.Ranked],
        options: AskGenerationOptions,
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async throws -> AskAnswer {
        try await turnstile.withTurn { () async throws -> AskAnswer in
            var lastFailure = AskFailure.tooMuchContext
            for attempt in Self.attempts(for: ranked) {
                try Task.checkCancellation()
                let built = await AskPromptBuilder.build(
                    question: question,
                    ranked: attempt,
                    contextSize: self.model.contextSize,
                    hasTool: !self.tools.isEmpty,
                    tokenCount: { [model = self.model] text in
                        try await model.tokenCount(for: text)
                    },
                )
                for tool in self.tools {
                    await tool.beginGeneration(numberingFrom: built.passages.count + 1)
                }

                do {
                    let answer = try await self.stream(built, options: options, into: continuation)
                    // Resolved here, inside the attempt that survived: the retry
                    // loop means the prompt whose numbering the citations refer
                    // to is whichever one did not throw `.tooMuchContext`, and
                    // the two before it were built from more passages.
                    var shown = Self.numbered(built.passages)
                    for tool in self.tools {
                        // The tool's excerpts continue the prompt's numbering,
                        // so they never collide; merged last regardless, because
                        // a collision would mean the tool numbered over the
                        // prompt and the tool's copy is what the model saw last.
                        shown.merge(await tool.passagesShown()) { _, fromTool in fromTool }
                    }
                    return AskAnswerParser.resolving(answer, among: shown)
                } catch let failure as AskFailure where failure == .tooMuchContext {
                    lastFailure = failure
                    IssaLog.info("ask prompt too large", [
                        "passages": String(built.passages.count),
                    ])
                    continue
                }
            }
            throw lastFailure
        }
    }

    /// All of them, then the best half, then the best two — strictly
    /// decreasing, and each attempt a subset of the one before it.
    ///
    /// A step that is not smaller than the one before it would fail in exactly
    /// the same way and cost the reader another five seconds to be told so.
    ///
    /// The best rather than the first: this took a `prefix`, and `ranked`
    /// arrives in book order, so a retry threw away the end of what the reader
    /// had read and kept the opening they remember perfectly well.
    static func attempts(for ranked: [PassageRanker.Ranked]) -> [[PassageRanker.Ranked]] {
        guard !ranked.isEmpty else { return [ranked] }
        var sizes: [Int] = []
        for size in [ranked.count, ranked.count / 2, 2] where size >= 1 {
            if let last = sizes.last, size >= last { continue }
            sizes.append(size)
        }
        return sizes.map { PassageRanker.best(ranked, count: $0) }
    }

    private func stream(
        _ built: AskPromptBuilder.Built,
        options: AskGenerationOptions,
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async throws -> AskAnswer {
        var raw = ""
        var shown = ""
        var hasAnswered = false
        let snapshots = model.answer(
            instructions: AskPromptBuilder.instructions,
            prompt: built.prompt,
            tools: tools,
            options: options,
        )
        for try await snapshot in snapshots {
            // Per snapshot: the reader who taps Cancel expects the words to
            // stop arriving, not to finish and then be thrown away.
            try Task.checkCancellation()
            raw = snapshot
            let visible = AskAnswerParser.visible(snapshot)
            guard visible != shown else { continue }
            shown = visible
            if !hasAnswered, !visible.isEmpty {
                hasAnswered = true
                continuation.yield(.phase(.answering))
            }
            continuation.yield(.partial(visible))
        }
        try Task.checkCancellation()
        // Returned rather than yielded: the answer still has to be vetted
        // against the boundary before the reader sees it as final.
        return AskAnswerParser.parse(raw)
    }

    // MARK: - Failures

    /// The plan's table. Everything the model can say about why it did not
    /// answer has already been turned into an `AskFailure` by whichever model
    /// said it — this is the catch-all for the rest, and it never leaks a
    /// framework error string into the sheet.
    static func failure(for error: any Error) -> AskFailure {
        if let failure = error as? AskFailure { return failure }
        IssaLog.error("ask failed", ["kind": String(describing: type(of: error))])
        return .other("Something went wrong answering that. Try again.")
    }

}
