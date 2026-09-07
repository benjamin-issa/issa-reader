import Foundation

/// A model that answers whatever it was told to answer.
///
/// It ships in the library rather than living in the test target on purpose.
/// The spoiler defence — the boundary, the trimming, the short-circuit, the
/// context retry, the serialising, the tool cap — is the part of this feature
/// that has to be *proved*, and none of it can be proved against a real 3B
/// model whose output is not a function of its input. Everything the engine
/// does is therefore asserted against this, and the real model is checked
/// separately for the one thing only it can show: that a sensible question gets
/// a sensible answer.
///
/// An `actor` because the tests read back what the engine sent it, and the
/// engine sends from a task the test does not own.
public actor ScriptedAnswerModel: AnswerModel {
    /// One scripted reply, consumed in order.
    public struct Turn: Sendable {
        /// Snapshots, each the answer *so far* — the shape
        /// `LanguageModelSession.streamResponse` actually produces, not deltas.
        public var partials: [String]
        /// Thrown instead of finishing. `AskFailure.tooMuchContext` is how a
        /// context-window retry is driven.
        public var failure: (any Error & Sendable)?
        /// Suspends after this many partials until `release()` is called.
        ///
        /// This is what makes "cancelled halfway" and "two questions at once"
        /// deterministic tests rather than races against a sleep.
        public var holdsAfterPartials: Int?

        public init(
            partials: [String] = [],
            failure: (any Error & Sendable)? = nil,
            holdsAfterPartials: Int? = nil,
        ) {
            self.partials = partials
            self.failure = failure
            self.holdsAfterPartials = holdsAfterPartials
        }

        /// A turn that streams one answer, in the two snapshots a real stream
        /// would produce.
        public static func answer(_ text: String) -> Turn {
            Turn(partials: [String(text.prefix(text.count / 2)), text])
        }
    }

    /// Exactly what the engine asked for, so a test can assert on what the
    /// model was *told* — which is where every spoiler leak would show up.
    public struct Received: Sendable, Hashable {
        public var instructions: String
        public var prompt: String
        public var toolNames: [String]
        public var options: AskGenerationOptions
    }

    /// For driving the engine's catch-all branch.
    public enum ScriptedError: Error, Sendable { case scripted }

    private var turns: [Turn]
    private var index = 0
    public private(set) var received: [Received] = []
    public private(set) var prewarmCount = 0

    /// The most generations that were ever in flight at once.
    ///
    /// So a turnstile test can assert the thing it means. `received.count`
    /// after a sleep only says how many *started*, which two questions
    /// answering one after the other and two answering at once can both
    /// satisfy depending on where the sleep lands; this cannot be one when the
    /// serialising is broken.
    public private(set) var peakConcurrency = 0
    private var inFlight = 0

    /// The window the engine budgets against. 4,096 is the real one; a test
    /// that wants to force trimming passes something small.
    public nonisolated let contextSize: Int
    /// Characters per token, so a test can do the arithmetic in its head.
    private let charactersPerToken: Int
    private let supportedLanguages: Set<String>?

    /// - Parameters:
    ///   - turns: consumed in order; the last one repeats once they run out, so
    ///     a test that only cares about one answer writes one turn.
    ///   - charactersPerToken: the fake tokeniser's rate. Four is close enough
    ///     to the real one that a budget test written against it means
    ///     something.
    ///   - supportedLanguages: `nil` means every language, which is what a test
    ///     about anything else wants.
    public init(
        turns: [Turn] = [.answer("Alice followed a white rabbit down the hole.\nSources: 1")],
        contextSize: Int = 4_096,
        charactersPerToken: Int = 4,
        supportedLanguages: Set<String>? = nil,
    ) {
        self.turns = turns
        self.contextSize = contextSize
        self.charactersPerToken = charactersPerToken
        self.supportedLanguages = supportedLanguages
    }

    // MARK: - AnswerModel

    public nonisolated func answer(
        instructions: String,
        prompt: String,
        tools: [any AskTool],
        options: AskGenerationOptions,
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.play(
                    Received(
                        instructions: instructions,
                        prompt: prompt,
                        toolNames: tools.map(\.name),
                        options: options,
                    ),
                    into: continuation,
                )
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func tokenCount(for text: String) async throws -> Int {
        Int((Double(text.count) / Double(charactersPerToken)).rounded(.up))
    }

    public func prewarm() async { prewarmCount += 1 }

    public nonisolated func supportsLanguage(_ bcp47: String?) -> Bool {
        guard let supportedLanguages else { return true }
        guard let bcp47, !bcp47.isEmpty else { return true }
        return supportedLanguages.contains(String(bcp47.prefix(2)).lowercased())
    }

    // MARK: - Playing a turn

    private func play(
        _ call: Received, into continuation: AsyncThrowingStream<String, any Error>.Continuation,
    ) async {
        inFlight += 1
        peakConcurrency = max(peakConcurrency, inFlight)
        defer { inFlight -= 1 }

        received.append(call)
        let turn = turns.isEmpty
            ? Turn.answer("The story hasn't revealed that yet.")
            : turns[min(index, turns.count - 1)]
        index += 1

        do {
            for (emitted, partial) in turn.partials.enumerated() {
                try Task.checkCancellation()
                continuation.yield(partial)
                if turn.holdsAfterPartials == emitted + 1 { try await hold() }
            }
            if turn.partials.isEmpty, turn.holdsAfterPartials != nil { try await hold() }
            if let failure = turn.failure {
                continuation.finish(throwing: failure)
            } else {
                continuation.finish()
            }
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - The gate

    private var holders: [CheckedContinuation<Void, any Error>] = []
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var isHolding = false

    private func hold() async throws {
        isHolding = true
        for waiter in holdWaiters { waiter.resume() }
        holdWaiters.removeAll()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { holders.append($0) }
        } onCancel: {
            Task { await self.cancelHold() }
        }
    }

    private func cancelHold() {
        isHolding = false
        for holder in holders { holder.resume(throwing: CancellationError()) }
        holders.removeAll()
    }

    /// Suspends the caller until the scripted stream has actually stopped at its
    /// hold — the point at which a test knows the engine is mid-answer and can
    /// cancel it, or ask a second question, without racing anything.
    public func waitUntilHolding() async {
        guard !isHolding else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    /// Lets a held stream finish.
    public func release() {
        isHolding = false
        for holder in holders { holder.resume() }
        holders.removeAll()
    }
}
