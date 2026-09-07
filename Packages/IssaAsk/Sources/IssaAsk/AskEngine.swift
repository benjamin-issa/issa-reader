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
/// An `actor` for two reasons. Questions are serialised — the on-device model
/// answers one at a time anyway, and a second `LanguageModelSession` running
/// concurrently fails with `concurrentRequests` — and the index handle, the
/// tools' per-generation state and the queue all need one owner.
public actor AskEngine {
    private let model: any AnswerModel
    /// Held publicly because the app also deletes indexes from it when a
    /// download goes, and there must be exactly one of these per process:
    /// two would open the same SQLite file twice.
    public nonisolated let store: AskIndexStore
    private let tools: [any AskTool]

    /// - Parameter tools: the `searchBook` tool, or nothing.
    ///
    ///   It is a constructor argument rather than a constant so it can be
    ///   switched off with one flag: the 3B model is only moderately reliable at
    ///   deciding when to search, and every round trip is another three to six
    ///   seconds on a phone. If the measurement goes against it, this is the
    ///   line that changes — and the engine is otherwise identical with and
    ///   without it, which is what makes the comparison worth anything.
    public init(model: any AnswerModel, store: AskIndexStore, tools: [any AskTool] = []) {
        self.model = model
        self.store = store
        self.tools = tools
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
    public func prewarm() async { await model.prewarm() }

    /// The two chips under the question field.
    ///
    /// Falls back to the generic pair when the index is not built yet, so the
    /// sheet has something to draw immediately rather than two empty capsules
    /// that fill in eight seconds later.
    public func suggestions(source: BookSource, boundary: ReadingBoundary) async -> [String] {
        guard await store.isPrepared(source: source),
              let names = try? await store.topNames(
                  in: source.bookUUID, before: boundary, limit: 1,
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
        await acquire()
        defer { releaseTurn() }
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
            continuation.yield(.answered(AskAnswer(
                text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
            )))

        // The book states the answer in so many words, so there is nothing to
        // think about and no `.thinking` phase to show. It is still vetted:
        // the sentence was assembled from the book, but the guard is cheap and
        // an unvetted path is a path somebody will later route around.
        case let .answered(answer, _):
            continuation.yield(.answered(
                try await vetted(
                    answer, question: sanitised,
                    bookUUID: source.bookUUID, boundary: boundary,
                ),
            ))

        case let .evidence(ranked, _):
            try Task.checkCancellation()
            continuation.yield(.phase(.thinking))
            let generated = try await generate(
                question: sanitised, ranked: ranked, into: continuation,
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
        return AskAnswer(
            text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
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
    private func generate(
        question: String,
        ranked: [PassageRanker.Ranked],
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async throws -> AskAnswer {
        var lastFailure = AskFailure.tooMuchContext
        for attempt in Self.attempts(for: ranked) {
            try Task.checkCancellation()
            let built = await AskPromptBuilder.build(
                question: question,
                ranked: attempt,
                contextSize: model.contextSize,
                hasTool: !tools.isEmpty,
                tokenCount: { [model] text in try await model.tokenCount(for: text) },
            )
            for tool in tools {
                await tool.beginGeneration(numberingFrom: built.passages.count + 1)
            }

            do {
                return try await stream(built, into: continuation)
            } catch let failure as AskFailure where failure == .tooMuchContext {
                lastFailure = failure
                IssaLog.info("ask prompt too large", ["passages": String(built.passages.count)])
                continue
            }
        }
        throw lastFailure
    }

    /// All of them, then half, then two — strictly decreasing.
    ///
    /// A step that is not smaller than the one before it would fail in exactly
    /// the same way and cost the reader another five seconds to be told so.
    static func attempts(for ranked: [PassageRanker.Ranked]) -> [[PassageRanker.Ranked]] {
        guard !ranked.isEmpty else { return [ranked] }
        var sizes: [Int] = []
        for size in [ranked.count, ranked.count / 2, 2] where size >= 1 {
            if let last = sizes.last, size >= last { continue }
            sizes.append(size)
        }
        return sizes.map { Array(ranked.prefix($0)) }
    }

    private func stream(
        _ built: AskPromptBuilder.Built,
        into continuation: AsyncThrowingStream<AskEvent, any Error>.Continuation,
    ) async throws -> AskAnswer {
        var raw = ""
        var shown = ""
        var hasAnswered = false
        let snapshots = model.answer(
            instructions: AskPromptBuilder.instructions,
            prompt: built.prompt,
            tools: tools,
            options: AskGenerationOptions(
                maximumResponseTokens: AskPromptBuilder.Budget.responseTokens,
            ),
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

    // MARK: - One at a time

    /// A plain actor turnstile.
    ///
    /// The on-device model rejects a second concurrent session outright, and a
    /// reader who asks again before the first answer lands should get the second
    /// answer rather than an error — so the second question waits rather than
    /// racing. It waits *before* checking its own cancellation, which means a
    /// cancelled second question still holds its place in the queue for as long
    /// as the first one runs; that is the queue working, not a leak, and it
    /// releases the moment its turn comes.
    private var isAnswering = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard isAnswering else { isAnswering = true; return }
        await withCheckedContinuation { queue.append($0) }
    }

    private func releaseTurn() {
        guard !queue.isEmpty else { isAnswering = false; return }
        queue.removeFirst().resume()
    }
}
