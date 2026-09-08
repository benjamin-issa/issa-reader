import Foundation
import Testing

@testable import IssaAsk

struct AskPromptBuilderTests {
    /// A tokeniser whose arithmetic a reader of this file can do in their head:
    /// four characters to the token.
    static let counter: AskPromptBuilder.TokenCounter = { text in
        Int((Double(text.count) / 4).rounded(.up))
    }

    /// Book order in, and by default the priority the general path would have
    /// given them — best first, which is the one arrangement where trimming
    /// from the bottom looked correct.
    static func ranked(
        _ passages: [Passage], priorities: [Int]? = nil,
    ) -> [PassageRanker.Ranked] {
        passages.enumerated().map { index, passage in
            PassageRanker.Ranked(
                retrieved: RetrievedPassage(passage: passage, bm25: -1, isTruncated: false),
                priority: priorities?[index] ?? index,
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

    /// Passages cut from the book's own prose, for the questions that are about
    /// whether a real prompt fits rather than about what the trimming drops.
    ///
    /// `passage(_:words:)` above makes tokens nearly twice as wide as English —
    /// "word3x47" is eight characters where *Alice* averages about 5.35 to the
    /// word including the space between them. That is harmless when the
    /// assertion is which passages survived, and quite wrong when it is whether
    /// fifteen of them fit inside a budget measured in characters.
    static func prosePassages(_ count: Int, words: Int) throws -> [Passage] {
        let chapter = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let all = chapter.split(whereSeparator: \.isWhitespace).map(String.init)
        guard all.count >= count * words else { return [] }
        return (0 ..< count).map { ordinal in
            let text = all[(ordinal * words) ..< ((ordinal + 1) * words)].joined(separator: " ")
            return Passage(
                spineIndex: AskFixture.Spine.chapterI, ordinal: ordinal,
                start: ordinal * 1_000, end: ordinal * 1_000 + text.count,
                words: words, text: text,
            )
        }
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

    @Test("the weakest passages are sacrificed, wherever in the book they sit")
    func trimsByPriorityNotByPosition() async throws {
        let passages = (0 ..< 6).map { Self.passage($0, words: 90) }
        // Every caller passes book order, and the trimming used to drop from
        // the end of it — so a recap lost the chapter the reader had just
        // closed. Here the best evidence is the last passage in the book and
        // the worst is the first, which is what a recap looks like.
        let built = await AskPromptBuilder.build(
            question: "What happened?",
            ranked: Self.ranked(passages, priorities: [5, 4, 3, 2, 1, 0]),
            contextSize: 1_400, hasTool: false, tokenCount: Self.counter,
        )
        try #require(built.dropped > 0)
        #expect(built.passages == Array(passages.suffix(built.passages.count)))
    }

    @Test("what survives is numbered in reading order, not in rank order")
    func numbersInReadingOrder() async throws {
        let passages = (0 ..< 6).map { Self.passage($0, words: 90) }
        let built = await AskPromptBuilder.build(
            question: "What happened?",
            // Best in the middle, worst at either end, so a builder that showed
            // its survivors in rank order would open the prompt with ordinal 3.
            ranked: Self.ranked(passages, priorities: [4, 2, 1, 0, 3, 5]),
            contextSize: 1_400, hasTool: false, tokenCount: Self.counter,
        )
        try #require(built.passages.count > 1)
        try #require(built.dropped > 0)
        // The best of them survive…
        #expect(Set(built.passages.map(\.ordinal))
            == Set([3, 2, 1, 4, 0, 5].prefix(built.passages.count)))
        // …and the model reads them in the order the book puts them. The
        // instructions say the excerpts are in reading order, and a model
        // handed events out of sequence invents a chronology to explain them.
        #expect(built.passages.map(\.ordinal) == built.passages.map(\.ordinal).sorted())
        #expect(built.prompt.contains(AskPromptBuilder.excerpts(built.passages)))
    }

    @Test("registering a tool lowers the passage budget")
    func toolLowersTheCeiling() async throws {
        // Sized from the ceiling rather than hand-counted. Twelve 90-word
        // passages were far over the old ceiling and are over the new one by a
        // hair, so the next tune of either number would have left this test
        // passing while asserting nothing at all.
        var passages: [Passage] = []
        repeat {
            passages.append(Self.passage(passages.count, words: 90))
        } while AskPromptBuilder.estimatedTokens(AskPromptBuilder.excerpts(passages))
            <= AskPromptBuilder.Budget.passageCeiling

        let without = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 100_000, hasTool: false, tokenCount: Self.counter,
        )
        let with = await AskPromptBuilder.build(
            question: "What happened?", ranked: Self.ranked(passages),
            contextSize: 100_000, hasTool: true, tokenCount: Self.counter,
        )
        // Without an overflow of the higher ceiling neither ceiling is
        // consulted, and the comparison below compares two whole corpora.
        try #require(without.dropped > 0)
        // The tool's schema is in the window, and its output has to fit in what
        // is left when the model calls it.
        #expect(
            AskPromptBuilder.Budget.passageCeilingWithTool
                < AskPromptBuilder.Budget.passageCeiling,
        )
        #expect(with.passages.count < without.passages.count)
    }

    @Test("fifteen excerpts of the book's own prose fit inside the budget")
    func fifteenExcerptsSurviveTheBudget() async throws {
        // The excerpt count went to fifteen and the ceiling had to go with it.
        // Fifteen 90-word excerpts are about 7,500 characters, which the cheap
        // `/3.6` pre-pass scores at roughly 2,100 tokens — and that pass runs
        // first and never un-does itself, so at the old 1,800 ceiling the set
        // was trimmed back to about twelve before the real tokeniser was ever
        // consulted. The change would have shipped inert, with every test in
        // this file still green.
        let passages = try Self.prosePassages(
            AskRetriever.Limits.excerpts, words: PassageChunker.Limits.targetWords,
        )
        try #require(passages.count == AskRetriever.Limits.excerpts)
        // The density is the whole point of using the book's own words, so it
        // is asserted rather than assumed: *Alice* runs to about 5.35
        // characters a word including the space, and `passage(_:words:)` above
        // makes tokens nearly twice that wide.
        let density = Double(passages.map(\.text.count).reduce(0, +))
            / Double(AskRetriever.Limits.excerpts * PassageChunker.Limits.targetWords)
        #expect(density > 4.5 && density < 6.5, "\(density) characters a word")

        for hasTool in [false, true] {
            let built = await AskPromptBuilder.build(
                question: "What has happened so far?", ranked: Self.ranked(passages),
                // The window a real device reports, and the estimate standing in
                // for the real tokeniser — the conservative end of what it
                // measures on English prose, so a pass here is not a pass bought
                // from a lenient fake.
                contextSize: 4_096, hasTool: hasTool,
                tokenCount: { AskPromptBuilder.estimatedTokens($0) },
            )
            #expect(built.dropped == 0, "hasTool: \(hasTool)")
            #expect(built.passages.count == AskRetriever.Limits.excerpts, "hasTool: \(hasTool)")
        }
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
