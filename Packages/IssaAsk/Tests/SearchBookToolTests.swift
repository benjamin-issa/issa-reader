#if canImport(FoundationModels)
import Foundation
import Testing

@testable import IssaAsk

/// The tool is the one place the model is allowed to ask for more of the book,
/// so it is the one place a spoiler could get in from the model's side.
struct SearchBookToolTests {
    @Test("the tool stops after two searches and says so")
    func capsItselfAtTwoCalls() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)

        let first = try await tool.call(arguments: .init(query: "rabbit"))
        let second = try await tool.call(arguments: .init(query: "duchess"))
        let third = try await tool.call(arguments: .init(query: "queen"))

        #expect(first != SearchBookTool.exhausted)
        #expect(second != SearchBookTool.exhausted)
        // Each round trip is another three to six seconds on a phone, and a 3B
        // model told nothing will search five times for rephrasings of one
        // question. Phrased as an instruction rather than an error, so the model
        // answers from what it has instead of apologising and stopping.
        #expect(third == SearchBookTool.exhausted)
        #expect(tool.callLimit == 2)
    }

    @Test("the budget is fresh for each generation")
    func budgetResetsPerGeneration() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        _ = try await tool.call(arguments: .init(query: "rabbit"))
        _ = try await tool.call(arguments: .init(query: "duchess"))
        #expect(try await tool.call(arguments: .init(query: "queen")) == SearchBookTool.exhausted)

        // A tool that counted across questions would spend its two searches on
        // the reader's first question and be useless for the rest of the book.
        await tool.beginGeneration(numberingFrom: 4)
        #expect(try await tool.call(arguments: .init(query: "rabbit")) != SearchBookTool.exhausted)
    }

    @Test("the tool cannot reach past the boundary either")
    func enforcesTheBoundary() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        // The boundary is captured at init from the same value the first-pass
        // retrieval used; there is no path through this type that can reach a
        // passage the reader has not read, whatever the model asks for.
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        let result = try await tool.call(arguments: .init(query: "Cheshire Cat grin"))
        #expect(!result.lowercased().contains("cheshire"))
    }

    @Test("its excerpts continue the prompt's numbering without a gap")
    func numbersAfterThePrompt() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        let result = try await tool.call(arguments: .init(query: "duchess baby pepper"))
        // A second `[1]` is a citation the sheet cannot tell from the first.
        #expect(result.hasPrefix("[7] (Section "))
        let second = try await tool.call(arguments: .init(query: "cat grin"))

        // Consecutive, not `[7]` then `[9]`. The budget used to advance by a
        // fixed two whatever the search emitted, so one match — or a token cap
        // that bit — left a hole in the numbering, and every citation past the
        // hole named an excerpt that did not exist.
        let first = Self.ordinals(in: result)
        let rest = Self.ordinals(in: second)
        try #require(!first.isEmpty)
        try #require(!rest.isEmpty)
        #expect(first + rest == Array(7 ..< (7 + first.count + rest.count)))
        #expect(await tool.passagesShown().keys.sorted() == first + rest)
    }

    /// The ordinals a stretch of excerpt text actually numbers itself with.
    static func ordinals(in excerpts: String) -> [Int] {
        excerpts.components(separatedBy: "\n\n").compactMap { block in
            guard let close = block.firstIndex(of: "]"), block.hasPrefix("[") else { return nil }
            return Int(block[block.index(after: block.startIndex) ..< close])
        }
    }

    @Test("a search that matches nothing spends no ordinals")
    func noMatchesCostsNoNumbers() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        #expect(try await tool.call(arguments: .init(query: "zxqwv")) == SearchBookTool.noMatches)
        // The second search is still `[7]`: nothing was shown, so nothing was
        // numbered, and skipping to `[9]` would be a hole in the middle of the
        // prompt the model is reading.
        let second = try await tool.call(arguments: .init(query: "duchess baby pepper"))
        #expect(second.hasPrefix("[7] (Section "))
    }

    @Test("the tool reports every excerpt it showed, by its ordinal")
    func reportsWhatItShowed() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        // A tool that retains nothing is a tool whose excerpts can be cited and
        // never shown: `call` returns a String, and before this every citation
        // in the tool's own range resolved to nothing whatever the numbering.
        await tool.beginGeneration(numberingFrom: 7)
        let result = try await tool.call(arguments: .init(query: "duchess baby pepper"))
        try #require(result != SearchBookTool.noMatches)

        let shown = await tool.passagesShown()
        #expect(shown.count == Self.ordinals(in: result).count)
        for ordinal in Self.ordinals(in: result) {
            let passage = try #require(shown[ordinal])
            #expect(result.contains("[\(ordinal)] (Section \(passage.spineIndex + 1)) "))
        }
    }

    @Test("a new generation forgets what the last one showed")
    func forgetsBetweenGenerations() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        _ = try await tool.call(arguments: .init(query: "duchess baby pepper"))
        #expect(!(await tool.passagesShown().isEmpty))

        // A context-window retry is a fresh session with an empty transcript and
        // a prompt with a different number of excerpts in it. Keeping the last
        // one's map would resolve `[7]` to a paragraph the model never saw.
        await tool.beginGeneration(numberingFrom: 4)
        #expect(await tool.passagesShown().isEmpty)
    }

    @Test("a search that matches nothing says so rather than returning empty")
    func reportsNoMatches() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        await tool.beginGeneration(numberingFrom: 3)
        #expect(try await tool.call(arguments: .init(query: "zxqwv")) == SearchBookTool.noMatches)
    }

    @Test("the tool searches the way the first pass did, subject and all")
    func usesTheSameRetrieval() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)

        // The tool used to call `QueryTerms.extract` with no known names at
        // all, and with no subject required — so a follow-up search for
        // "Alice's cat" came back with paragraphs about cats, or about Alice,
        // whichever bm25 liked best.
        let result = try await tool.call(arguments: .init(query: "Alice's cat"))
        try #require(result != SearchBookTool.noMatches)
        for excerpt in result.components(separatedBy: "\n\n") {
            #expect(excerpt.lowercased().contains("alice"))
            #expect(excerpt.lowercased().contains("cat"))
        }
    }

    @Test("the tool may not answer the question itself")
    func neverAnswersOutright() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, bookUUID: AskFixture.bookUUID,
            boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        await tool.beginGeneration(numberingFrom: 7)

        // The model has already been called by the time this runs, and handing
        // it a finished sentence in place of excerpts is not a search result.
        let result = try await tool.call(arguments: .init(query: "Who is Alice's sister?"))
        #expect(result.hasPrefix("[7] (Section ") || result == SearchBookTool.noMatches)
        #expect(!result.hasPrefix("Alice's sister is"))
    }

    @Test("what comes back fits in roughly three hundred tokens")
    func capsItsOutput() {
        // The answer still has to fit in the window beside the excerpts that
        // are already there.
        let long = Passage(
            spineIndex: 4, ordinal: 0, start: 0, end: 8_000, words: 1_400,
            text: String(repeating: "the duchess sneezed again and again. ", count: 200),
        )
        let (text, shown) = SearchBookTool.excerpts([long, long], numberingFrom: 7)
        #expect(AskPromptBuilder.estimatedTokens(text) <= SearchBookTool.tokenCap + 20)
        #expect(text.hasSuffix("…"))
        // What is reported is what was written, not what was offered: the cap
        // bit, and the ordinal the second passage would have had must not be
        // resolvable.
        #expect(shown.keys.sorted() == Self.ordinals(in: text))
    }
}
#endif
