import Foundation
import Testing

@testable import IssaAsk

struct AskPromptBuilderTests {
    /// A tokeniser whose arithmetic a reader of this file can do in their head:
    /// four characters to the token.
    static let counter: AskPromptBuilder.TokenCounter = { text in
        Int((Double(text.count) / 4).rounded(.up))
    }

    static func ranked(_ passages: [Passage]) -> [PassageRanker.Ranked] {
        passages.map {
            PassageRanker.Ranked(
                retrieved: RetrievedPassage(passage: $0, bm25: -1, isTruncated: false), score: 0,
            )
        }
    }

    static func passage(_ ordinal: Int, spine: Int = 2, words: Int = 60) -> Passage {
        let text = (0 ..< words).map { "word\(ordinal)x\($0)" }.joined(separator: " ")
        return Passage(
            spineIndex: spine, ordinal: ordinal, start: ordinal * 1_000,
            end: ordinal * 1_000 + text.count, words: words, text: text,
        )
    }

    // MARK: - What the model is never told

    @Test("the instructions name neither the book nor its author")
    func instructionsCarryNoIdentity() throws {
        let metadata = try AskFixture.package().metadata
        let title = try #require(metadata.title)
        let instructions = AskPromptBuilder.instructions.lowercased()

        // Tell this model the book is Alice's Adventures in Wonderland and it
        // will answer about the Queen of Hearts from memory, ten chapters ahead
        // of the reader. So the title and the author never leave the UI.
        #expect(!instructions.contains(title.lowercased()))
        for author in metadata.authors {
            #expect(!instructions.contains(author.lowercased()))
            // The surname alone is enough to identify the book.
            if let surname = author.split(separator: " ").last {
                #expect(!instructions.contains(surname.lowercased()))
            }
        }
        #expect(!instructions.contains("alice"))
        #expect(!instructions.contains("wonderland"))
    }

    @Test("the instructions carry an invented example, not a real book")
    func exampleIsInvented() {
        // A few-shot example drawn from real fiction teaches the model that
        // recalling published work is what this task is for — the one thing
        // these instructions exist to forbid.
        #expect(AskPromptBuilder.instructions.contains("Tobias"))
        #expect(AskPromptBuilder.instructions.contains("DO NOT"))
        #expect(AskPromptBuilder.instructions.contains(AskAnswerParser.notYetSentinel))
    }

    @Test("chapters are ordinals, never navigation titles")
    func excerptsUseOrdinals() throws {
        let package = try AskFixture.package()
        let navigationTitles = package.navigation.map(\.title)
        try #require(navigationTitles.contains { $0.contains("Rabbit-Hole") })

        let text = AskPromptBuilder.excerpts([Self.passage(0, spine: 2)])
        // "Down the Rabbit-Hole" identifies the book as surely as its title
        // does, and a title like "The Death of Ned Stark" is a spoiler by itself.
        #expect(text.hasPrefix("[1] (Section 3)"))
        for title in navigationTitles where title.count > 8 {
            #expect(!text.contains(title))
        }
    }

    @Test("the question goes in the prompt and only in the prompt")
    func questionStaysOutOfInstructions() async {
        let question = "Who is the Duchess's cook?"
        let built = await AskPromptBuilder.build(
            question: question, ranked: Self.ranked([Self.passage(0)]),
            contextSize: 4_096, hasTool: false, tokenCount: Self.counter,
        )
        #expect(built.prompt.contains(question))
        #expect(!AskPromptBuilder.instructions.contains(question))
    }

    // MARK: - Budget

    @Test("trimming drops whole passages and never splits one")
    func trimmingNeverSplitsAPassage() async {
        let passages = (0 ..< 6).map { Self.passage($0, words: 90) }
        let built = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            // Small enough that most of them have to go.
            contextSize: 1_400, hasTool: false, tokenCount: Self.counter,
        )
        #expect(built.dropped > 0)
        #expect(built.passages.count + built.dropped == passages.count)
        // Half a paragraph is worse than none: the model answers from the half
        // it was given and cites it with confidence, and the sentence that
        // qualified it is the one that was cut.
        for kept in built.passages {
            #expect(passages.contains(kept))
            #expect(built.prompt.contains(kept.displayText))
        }
    }

    @Test("the lowest-ranked passages are the ones sacrificed")
    func dropsFromTheBottom() async {
        let passages = (0 ..< 6).map { Self.passage($0, words: 90) }
        let built = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 1_400, hasTool: false, tokenCount: Self.counter,
        )
        // `ranked` arrives best first, so a question's best evidence is never
        // the thing thrown away to make room.
        #expect(built.passages == Array(passages.prefix(built.passages.count)))
    }

    @Test("registering a tool lowers the passage budget")
    func toolLowersTheCeiling() async {
        let passages = (0 ..< 12).map { Self.passage($0, words: 90) }
        let without = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 100_000, hasTool: false, tokenCount: Self.counter,
        )
        let with = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 100_000, hasTool: true, tokenCount: Self.counter,
        )
        // The tool's schema is in the window, and its output has to fit in what
        // is left when the model calls it.
        #expect(AskPromptBuilder.Budget.passageCeilingWithTool < AskPromptBuilder.Budget.passageCeiling)
        #expect(with.passages.count < without.passages.count)
    }

    @Test("the ceiling holds even when the context window is enormous")
    func ceilingCapsAHugeWindow() async throws {
        let passages = (0 ..< 40).map { Self.passage($0, words: 90) }
        let built = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 1_000_000, hasTool: false, tokenCount: Self.counter,
        )
        let excerptTokens = try await Self.counter(AskPromptBuilder.excerpts(built.passages))
        // A bigger window in a later OS must not silently start sending a
        // quarter of the book to the model.
        #expect(excerptTokens <= AskPromptBuilder.Budget.passageCeiling)
    }

    @Test("one enormous passage is sent whole rather than cut or dropped")
    func keepsTheLastPassageWhole() async {
        let huge = Self.passage(0, words: 4_000)
        let built = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked([huge]),
            contextSize: 4_096, hasTool: false, tokenCount: Self.counter,
        )
        #expect(built.passages == [huge])
        #expect(built.prompt.contains(huge.displayText))
    }

    @Test("no passages still produces a well-formed prompt")
    func handlesNoPassages() async {
        let built = await AskPromptBuilder.build(
            question: "What happened?", ranked: [],
            contextSize: 4_096, hasTool: false, tokenCount: Self.counter,
        )
        #expect(built.passages.isEmpty)
        #expect(built.prompt.contains("Question: What happened?"))
    }
}
