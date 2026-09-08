import Foundation

/// Everything the model is told, and nothing else.
///
/// Three rules govern this file, and all three are spoiler defence rather than
/// prompt craft:
///
/// 1. **The question never goes in the instructions.** Instructions are trusted
///    and constant; user text in them is an injection surface, and Apple's own
///    guidance is explicit about it.
/// 2. **The title and the author are never sent.** The model has read the
///    canon. Tell it the book is *Alice's Adventures in Wonderland* and it will
///    happily answer about the Queen of Hearts from memory, forty chapters
///    ahead of the reader.
/// 3. **Chapters are ordinals, never navigation titles.** "Down the
///    Rabbit-Hole" identifies the book as surely as its title does, and a title
///    like "The Death of Ned Stark" is a spoiler in itself.
public enum AskPromptBuilder {
    // MARK: - Instructions

    /// Constant, trusted, and carrying one invented example.
    ///
    /// The example is invented — "Tobias", a character in no book — deliberately.
    /// A few-shot example drawn from real fiction teaches the model that
    /// recalling published work is what this task is for, which is the one
    /// behaviour these instructions exist to forbid.
    ///
    /// "DO NOT" in capitals because the on-device model responds to it where it
    /// ignores a politely-phrased constraint; the length is stated explicitly
    /// because it otherwise writes either one clause or a page.
    public static let instructions = """
    You answer a reader's question about a novel they are part-way through.

    You are given numbered excerpts from the part of the book they have already \
    read, in reading order. They are the only thing you know about this story.

    Rules:
    - Answer ONLY from the excerpts. DO NOT use anything you remember about any \
    book, film, play or author, even if you recognise the story.
    - DO NOT guess, predict or hint at what happens later in the book.
    - If the excerpts do not contain the answer, reply with exactly: \
    The story hasn't revealed that yet.
    - If the excerpts only mention a person in passing, say only what they \
    state about them.
    - Write two to four sentences of plain prose. No lists, no headings.
    - End with a final line naming the excerpts you used, like: Sources: 1, 3

    Example:

    Excerpts:
    [1] (Section 2) Tobias set down the lantern and counted the coins again. \
    Nineteen. Not enough for the crossing, and the ferryman would not wait.
    [2] (Section 3) "You're the smith's boy," said the woman. Tobias nodded, \
    and did not say that the smith had thrown him out a fortnight since.

    Question: What is Tobias short of?

    Answer:
    Tobias is short of money for the crossing — he counts nineteen coins and \
    knows it is not enough, and the ferryman will not wait. He is also without \
    a home, having been thrown out by the smith a fortnight earlier.
    Sources: 1, 2
    """

    // MARK: - Budget

    /// The numbers that decide how much of the book fits.
    public enum Budget {
        /// What the answer is allowed to take.
        public static let responseTokens = 250
        /// Slack for the tokeniser disagreeing with the estimate, and for
        /// whatever the framework adds around a prompt. Cheap insurance: the
        /// cost of being wrong is a full retry, several seconds each.
        public static let margin = 256
        /// The ceiling on passages regardless of what is left over, so a bigger
        /// context window in a later OS does not silently start sending a
        /// quarter of the book.
        ///
        /// Raised with the excerpt count, and it had to be: fifteen 90-word
        /// excerpts are about 7,530 characters, which the cheap `/3.6` pass
        /// below scores at roughly 2,092 tokens. That pass runs first and never
        /// un-does itself, so at 1,800 the set was trimmed back to about twelve
        /// before the real tokeniser was ever consulted — and the count would
        /// have shipped inert.
        public static let passageCeiling = 3_000
        /// Lower with a tool registered: its schema is in the window, and its
        /// output has to fit in what remains when it is called.
        ///
        /// The app always registers the search tool, so this is the only
        /// ceiling a reader actually meets. At it, with two searches, the
        /// window comes to roughly 3,900 of 4,096 — it fits, with little to
        /// spare, and a book of long paragraphs can still overflow into a
        /// `.tooMuchContext` retry. If that shows up, the levers are
        /// `SearchBookTool.tokenCap` and its call limit, in that order.
        public static let passageCeilingWithTool = 2_400
        /// Characters per token. Measured against English prose with the
        /// on-device tokeniser; used only to avoid asking the model to count
        /// something obviously far too large.
        public static let charactersPerToken = 3.6
    }

    /// A cheap estimate, for the first pass before the real count is asked for.
    public static func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.count) / Budget.charactersPerToken).rounded(.up))
    }

    /// Counts tokens for real. Injected so the whole builder is testable
    /// without a model: the tests fake a tokeniser with known arithmetic and
    /// assert on the trimming, which is the part that can lose a passage.
    public typealias TokenCounter = @Sendable (String) async throws -> Int

    // MARK: - Building

    /// What was sent, and what survived the trimming.
    public struct Built: Sendable {
        public var prompt: String
        /// Book order, which is also the order they were numbered in, so
        /// citation `[2]` maps back to an excerpt the sheet can show.
        public var passages: [Passage]
        public var promptTokens: Int
        /// How many were dropped to make it fit — logged, never shown.
        public var dropped: Int
    }

    /// Packs as many of the ranked passages as fit and numbers what survives,
    /// in reading order.
    ///
    /// Never splits a passage. Half a paragraph is worse than none: the model
    /// answers from the half it was given and cites it with confidence, and the
    /// sentence that qualified it is the one that was cut.
    ///
    /// - Parameters:
    ///   - ranked: in book order, each carrying its `priority`. `best` decides
    ///     which survive and this only decides how many, because trimming on
    ///     position alone drops the passages nearest the reader — which on a
    ///     recap is the chapter they have just closed, and on "who is X" is
    ///     every sentence after the first six.
    ///   - hasTool: whether a `searchBook` tool is registered, which lowers the
    ///     ceiling to leave room for its schema and its output.
    public static func build(
        question: String,
        ranked: [PassageRanker.Ranked],
        contextSize: Int,
        hasTool: Bool,
        tokenCount: TokenCounter,
    ) async -> Built {
        let ceiling = hasTool ? Budget.passageCeilingWithTool : Budget.passageCeiling
        let instructionTokens = (try? await tokenCount(instructions))
            ?? estimatedTokens(instructions)
        let emptyFrame = frame(question: question, excerpts: "")
        let framingTokenCount = (try? await tokenCount(emptyFrame))
            ?? estimatedTokens(emptyFrame)
        let available = min(
            ceiling,
            contextSize - instructionTokens - Budget.responseTokens
                - framingTokenCount - Budget.margin,
        )

        // How many, never which: `best` answers that, and it answers it the
        // same way every time round, so each pass through is a subset of the
        // last rather than a fresh selection.
        var count = ranked.count
        var kept = PassageRanker.best(ranked, count: count).map(\.retrieved.passage)
        // Cheap pass first: an obviously oversized set is trimmed on the
        // character estimate before the model is asked to count anything, which
        // on a phone is a real cost per call.
        while count > 1, estimatedTokens(excerpts(kept)) > available {
            count -= 1
            kept = PassageRanker.best(ranked, count: count).map(\.retrieved.passage)
        }
        // Then the real count, which is the one that decides.
        while !kept.isEmpty {
            let text = excerpts(kept)
            let tokens = (try? await tokenCount(text)) ?? estimatedTokens(text)
            if tokens <= available || kept.count == 1 {
                return Built(
                    prompt: frame(question: question, excerpts: text),
                    passages: kept,
                    promptTokens: tokens + framingTokenCount,
                    dropped: ranked.count - count,
                )
            }
            count -= 1
            kept = PassageRanker.best(ranked, count: count).map(\.retrieved.passage)
        }
        return Built(
            prompt: frame(question: question, excerpts: ""),
            passages: [],
            promptTokens: framingTokenCount,
            dropped: ranked.count - count,
        )
    }

    // MARK: - Text

    /// The numbered excerpts, exactly as the model sees them.
    ///
    /// `(Section k)` from `spineIndex`, one-based, never the navigation title.
    public static func excerpts(_ passages: [Passage]) -> String {
        passages.enumerated().map { index, passage in
            "[\(index + 1)] (Section \(passage.spineIndex + 1)) \(passage.displayText)"
        }.joined(separator: "\n\n")
    }

    /// The prompt around the excerpts. The question goes here, and only here.
    public static func frame(question: String, excerpts: String) -> String {
        """
        Excerpts:
        \(excerpts)

        Question: \(question)

        Answer:
        """
    }
}
