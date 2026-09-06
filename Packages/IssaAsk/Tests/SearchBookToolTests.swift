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
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
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
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
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
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        let result = try await tool.call(arguments: .init(query: "Cheshire Cat grin"))
        #expect(!result.lowercased().contains("cheshire"))
    }

    @Test("its excerpts continue the prompt's numbering")
    func numbersAfterThePrompt() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
        )
        await tool.beginGeneration(numberingFrom: 7)
        let result = try await tool.call(arguments: .init(query: "duchess baby pepper"))
        // A second `[1]` is a citation the sheet cannot tell from the first.
        #expect(result.hasPrefix("[7] (Section "))
        let second = try await tool.call(arguments: .init(query: "cat grin"))
        #expect(second.hasPrefix("[9] (Section "))
    }

    @Test("a search that matches nothing says so rather than returning empty")
    func reportsNoMatches() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
        )
        await tool.beginGeneration(numberingFrom: 3)
        #expect(try await tool.call(arguments: .init(query: "zxqwv")) == SearchBookTool.noMatches)
    }

    @Test("the tool searches the way the first pass did, subject and all")
    func usesTheSameRetrieval() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let tool = SearchBookTool(
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterVI),
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
            store: store, boundary: try AskFixture.endOf(spine: AskFixture.Spine.chapterI),
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
        let text = SearchBookTool.excerpts([long, long], numberingFrom: 7)
        #expect(AskPromptBuilder.estimatedTokens(text) <= SearchBookTool.tokenCap + 20)
        #expect(text.hasSuffix("…"))
    }
}
#endif
