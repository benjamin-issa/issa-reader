#if canImport(FoundationModels)
import Foundation
import FoundationModels
import IssaCore

/// The one way the model is allowed to ask for more of the book.
///
/// The reader chose this: the app searches first, and the model may refine.
/// Everything about the shape of it is a bound rather than a capability.
///
/// - **The book and the boundary are captured at `init`**, from the same values
///   the first-pass retrieval used, and every call goes through the same
///   `AskIndexStore.retrieve` with the same SQL clause. There is no path through
///   this type that can reach a passage the reader has not read, or a passage
///   from a book they are not reading, whatever the model asks for.
/// - **Two calls**, after which it says so in words the model can act on. Each
///   round trip is another three to six seconds on a phone, and a 3B model that
///   is told nothing will search five times for rephrasings of one question.
/// - **Roughly 300 tokens back**, because the answer still has to fit in the
///   window beside the excerpts that are already there.
///
/// A class rather than a struct because `beginGeneration` mutates the call
/// budget through a `Sendable` reference the session holds.
public final class SearchBookTool: AskTool, Tool {
    /// What the model may ask for. One string: a schema with fields for
    /// chapter or character invites the model to invent constraints, and the
    /// only thing retrieval can actually use is words.
    @Generable
    public struct Arguments {
        @Guide(description: "Words to look for, such as a character's name or a thing that happened.")
        public var query: String
    }

    public let name = "searchBook"

    /// Written in the second person and stating the bound, because the model
    /// reads this as instructions and behaves better when it knows the limit
    /// before it hits it.
    public let description = """
    Search the part of the book the reader has already read for more excerpts. \
    Use this only when the excerpts you were given do not answer the question. \
    You may search at most twice.
    """

    public var toolDescription: String { description }
    public let callLimit = 2

    /// What the model is told once it has spent its searches. Phrased as an
    /// instruction rather than an error: a 3B model handed "error" tends to
    /// apologise and stop, where this makes it answer from what it has.
    public static let exhausted = "No more searches are available; answer from what you have."
    static let noMatches = "Nothing in the part of the book the reader has read matches that."

    /// Roughly. Counted with the builder's character estimate rather than the
    /// model's tokeniser: this runs mid-generation, where an await on the
    /// tokeniser is latency the reader is watching.
    static let tokenCap = 300
    /// How many passages one search may return, before the token cap trims it
    /// further.
    static let passageLimit = 2

    private let store: AskIndexStore
    /// Captured at `init` alongside the boundary and for the same reason: one
    /// store holds every book on the shelf, and a search that named its book
    /// later than this could be answered from whichever book was opened since.
    private let bookUUID: String
    private let boundary: ReadingBoundary
    private let budget = Budget()

    public init(store: AskIndexStore, bookUUID: String, boundary: ReadingBoundary) {
        self.store = store
        self.bookUUID = bookUUID
        self.boundary = boundary
    }

    // MARK: - AskTool

    public func beginGeneration(numberingFrom firstOrdinal: Int) async {
        await budget.begin(numberingFrom: firstOrdinal)
    }

    public func passagesShown() async -> [Int: Passage] {
        await budget.shown
    }

    // MARK: - Tool

    public func call(arguments: Arguments) async throws -> String {
        guard let firstOrdinal = await budget.spend(limit: callLimit) else {
            return Self.exhausted
        }
        // The same retrieval the first pass used, which is the point: the tool
        // used to call `QueryTerms.extract` with no known names, so a name the
        // book invented — the ones readers ask about — was not a name to it at
        // all, and the model's follow-up search returned the wrong paragraphs.
        //
        // `allowsFastPath: false`: the model has already been called, and
        // handing it a finished sentence in place of excerpts is not a search
        // result.
        let retriever = AskRetriever(
            store: store, bookUUID: bookUUID, boundary: boundary, allowsFastPath: false,
        )
        let retrieval = try? await retriever.retrieve(
            question: arguments.query, limit: Self.passageLimit,
        )
        var ranked: [PassageRanker.Ranked] = []
        if case let .evidence(found, _) = retrieval { ranked = Array(found.prefix(Self.passageLimit)) }
        // Counts only, never the query: whether the model searches at all — and
        // what that costs in seconds — is the measurement the tool ships behind
        // a kill switch for, and there is no other way to see it from outside.
        IssaLog.debug("ask tool searched", ["found": String(ranked.count)])
        guard !ranked.isEmpty else { return Self.noMatches }
        let (text, shown) = Self.excerpts(ranked.map(\.passage), numberingFrom: firstOrdinal)
        await budget.record(shown)
        return text
    }

    /// Numbered excerpts in the prompt's own format, continuing its numbering,
    /// capped at roughly `tokenCap`.
    ///
    /// The last passage is truncated at a word boundary rather than dropped when
    /// it is the only one: the model asked for something, and a sentence of it
    /// is more use than being told there was nothing.
    ///
    /// - Returns: the text, and the passages that made it into it by the ordinal
    ///   they were given. Fewer than were offered whenever the token cap bit,
    ///   which is exactly why the count is reported rather than assumed.
    static func excerpts(
        _ passages: [Passage], numberingFrom firstOrdinal: Int,
    ) -> (text: String, shown: [Int: Passage]) {
        var lines: [String] = []
        var shown: [Int: Passage] = [:]
        var spent = 0
        for (offset, passage) in passages.enumerated() {
            let ordinal = firstOrdinal + offset
            let head = "[\(ordinal)] (Section \(passage.spineIndex + 1)) "
            let room = Self.tokenCap - spent - AskPromptBuilder.estimatedTokens(head)
            guard room > 20 || lines.isEmpty else { break }
            let body = truncated(passage.displayText, toTokens: max(room, 20))
            lines.append(head + body)
            shown[ordinal] = passage
            spent += AskPromptBuilder.estimatedTokens(head + body)
            if spent >= Self.tokenCap { break }
        }
        return (lines.joined(separator: "\n\n"), shown)
    }

    static func truncated(_ text: String, toTokens tokens: Int) -> String {
        guard AskPromptBuilder.estimatedTokens(text) > tokens else { return text }
        let characters = Int(Double(tokens) * AskPromptBuilder.Budget.charactersPerToken)
        let clipped = text.prefix(max(characters, 1))
        guard let lastSpace = clipped.lastIndex(of: " ") else { return String(clipped) }
        return String(clipped[..<lastSpace]) + "…"
    }
}

// MARK: -

/// The tool's per-generation state, off the tool's own storage so the tool can
/// stay `Sendable` while the session calls it from wherever it likes.
///
/// The excerpt map lives here rather than on the tool for the same reason the
/// counter does, and it is why `passagesShown()` costs the tool no new mutable
/// state at all.
private actor Budget {
    private var used = 0
    private var nextOrdinal = 1
    /// Every excerpt this generation has handed the model, by its ordinal.
    /// Cleared by `begin`, because a context-window retry is a fresh session
    /// whose prompt has a different number of excerpts in it.
    private(set) var shown: [Int: Passage] = [:]

    func begin(numberingFrom ordinal: Int) {
        used = 0
        nextOrdinal = max(ordinal, 1)
        shown = [:]
    }

    /// The ordinal to number this call's excerpts from, or nil when the budget
    /// is spent.
    func spend(limit: Int) -> Int? {
        guard used < limit else { return nil }
        used += 1
        return nextOrdinal
    }

    /// What a call actually emitted, so the next one numbers from where it
    /// stopped.
    ///
    /// This used to advance by `passageLimit` whatever happened, while
    /// `excerpts` numbered consecutively from what it really wrote — so one
    /// match, a token cap that bit, or a search that found nothing left a hole:
    /// the model was handed `[7]` and then `[9]`, and every citation past the
    /// hole named an excerpt that did not exist.
    func record(_ excerpts: [Int: Passage]) {
        shown.merge(excerpts) { _, latest in latest }
        nextOrdinal += excerpts.count
    }
}
#endif
