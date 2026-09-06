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
              let names = try? await store.topNames(before: boundary, limit: 1)
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
        let (ranked, unmet) = try await retrieve(question: question, boundary: boundary)

        // Two ways the answer is "not yet", and both are settled here rather
        // than by the model. Nothing retrieved at all is the obvious one. The
        // other is a question naming somebody the book has not introduced:
        // retrieval happily returns six passages about the *other* words in the
        // question, and the model — asked "Who is the Cheshire Cat?" from the
        // end of Chapter I, handed excerpts containing no cat but Dinah —
        // answered from memory, ten chapters ahead of the reader. Instructions
        // that forbade it twice did not stop it; this does.
        if ranked.isEmpty || !unmet.isEmpty {
            IssaLog.info("ask answered as not yet revealed", ["unmet": String(unmet.count)])
            continuation.yield(.answered(AskAnswer(
                text: AskAnswerParser.notYetSentinel, citations: [], notYetRevealed: true,
            )))
            return
        }

        try Task.checkCancellation()
        continuation.yield(.phase(.thinking))
        try await generate(
            question: QueryTerms.sanitise(question), ranked: ranked, into: continuation,
        )
    }

    // MARK: - Retrieval

    /// The passages the model will see, and the words in the question the book
    /// has not used yet.
    private func retrieve(
        question: String, boundary: ReadingBoundary,
    ) async throws -> (ranked: [PassageRanker.Ranked], unmet: [String]) {
        // The book's own names, bounded by the position, so an invented one the
        // general-purpose tagger misses ("Cheshire") is still recognised as a
        // name — and a character not yet met is still not.
        let known = (try? await store.topNames(before: boundary, limit: Self.knownNameLimit)) ?? []
        let terms = QueryTerms.extract(from: question, knownNames: known)

        // A recap names nobody in particular, so it has nothing to be unmet.
        guard !terms.isRecap else {
            let recap = try await store.recapPassages(before: boundary, limit: Self.recapLimit)
            // Already the passages it wants, in order; ranking them by a query
            // with no terms in it would only shuffle them.
            return (recap.map { PassageRanker.Ranked(retrieved: $0, score: 0) }, [])
        }

        let unmet = try await store.unmetWords(terms.nameCandidates, before: boundary)
        // The retrieval is skipped when the answer is already known to be "not
        // yet": it would only cost a query whose results are thrown away.
        guard unmet.isEmpty else { return ([], unmet) }

        let candidates = try await store.retrieve(terms: terms, before: boundary)
        return (PassageRanker.rank(candidates, terms: terms, limit: Self.passageLimit), [])
    }

    /// How many of the book's names are consulted when reading a question.
    /// Generous: it costs one indexed query, and a name the list misses is a
    /// question that silently retrieves the wrong paragraphs.
    static let knownNameLimit = 200
    static let passageLimit = 6
    static let recapLimit = 6

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
    ) async throws {
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
                try await stream(built, into: continuation)
                return
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
    ) async throws {
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
        continuation.yield(.answered(AskAnswerParser.parse(raw)))
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
