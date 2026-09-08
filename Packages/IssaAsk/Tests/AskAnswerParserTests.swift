import Foundation
import Testing

@testable import IssaAsk

struct AskAnswerParserTests {
    // MARK: - The citation line

    @Test("the Sources line is stripped and turned into ordinals")
    func splitsSources() {
        let parsed = AskAnswerParser.parse("""
        Alice follows a white rabbit down a hole. She lands in a long hall.
        Sources: 1, 3
        """)
        #expect(parsed.text == "Alice follows a white rabbit down a hole. She lands in a long hall.")
        #expect(parsed.citations == [1, 3])
        #expect(!parsed.notYetRevealed)
    }

    @Test("only a line that begins with the label counts as a citation line")
    func ignoresTheWordInProse() {
        // "the sources: he said" inside an answer is prose, not a footer, and
        // cutting there would swallow the rest of the answer.
        let parsed = AskAnswerParser.parse("""
        She checked her sources: the book and the map.
        Sources: 2
        """)
        #expect(parsed.text == "She checked her sources: the book and the map.")
        #expect(parsed.citations == [2])
    }

    @Test("no citation line leaves the answer intact")
    func toleratesAMissingLine() {
        let parsed = AskAnswerParser.parse("She fell a very long way down.")
        #expect(parsed.text == "She fell a very long way down.")
        #expect(parsed.citations.isEmpty)
    }

    @Test("a section number in the citation line is not a citation")
    func ignoresASectionNumber() {
        // The excerpts the model is shown are literally `[1] (Section 3) …`, and
        // a 3B model copies the shape into its footer. With six excerpts sent,
        // the 4 here was in range, resolved, and put a paragraph from a
        // different part of the book under the answer.
        let parsed = AskAnswerParser.parse("""
        Alice met a rabbit.
        Sources: 1 and 2 (Section 4)
        """)
        #expect(parsed.citations == [1, 2])
    }

    // MARK: - Resolving citations

    /// Six excerpts, numbered the way the prompt numbers them.
    static func shown(_ count: Int) -> [Int: Passage] {
        Dictionary(uniqueKeysWithValues: (1 ... count).map { ordinal in
            (ordinal, Passage(
                spineIndex: ordinal, ordinal: 0, start: 0, end: 10, words: 2,
                text: "excerpt \(ordinal)",
            ))
        })
    }

    @Test("an ordinal naming no excerpt resolves to nothing")
    func dropsAnOrdinalNobodyNumbered() {
        // A 3B model handed six excerpts cites `[9]` often enough that this
        // cannot be an assertion. The raw claim is kept so the drop is visible.
        let answer = AskAnswerParser.resolving(
            AskAnswer(text: "She fell.", citations: [2, 9], notYetRevealed: false),
            among: Self.shown(6),
        )
        #expect(answer.citations == [2, 9])
        #expect(answer.sources.map(\.ordinal) == [2])
        #expect(answer.sources.first?.passage.text == "excerpt 2")
    }

    @Test("the same excerpt cited twice is one source")
    func deduplicates() {
        let answer = AskAnswerParser.resolving(
            AskAnswer(text: "She fell.", citations: [3, 1, 3], notYetRevealed: false),
            among: Self.shown(6),
        )
        // In the order the model cited them, so the first thing under the answer
        // is the excerpt it leaned on first.
        #expect(answer.sources.map(\.ordinal) == [3, 1])
    }

    @Test("an answer that cited nothing shows nothing")
    func citesNothing() {
        let answer = AskAnswerParser.resolving(
            AskAnswer(text: "She fell.", citations: [], notYetRevealed: false),
            among: Self.shown(6),
        )
        #expect(answer.sources.isEmpty)
    }

    // MARK: - Which three the row shows

    /// A cited excerpt with a rank of the test's choosing.
    static func source(_ ordinal: Int, priority: Int?) -> AskSource {
        AskSource(
            ordinal: ordinal,
            passage: Passage(
                spineIndex: ordinal, ordinal: 0, start: 0, end: 10, words: 2,
                text: "excerpt \(ordinal)",
            ),
            priority: priority,
        )
    }

    @Test("the row keeps the strongest few, in the order they were cited")
    func bestKeepsTheStrongestInCitedOrder() {
        // The stamp a recap leaves: retrieval hands the model fifteen excerpts
        // in book order while the ranker's own sort runs the other way, so
        // taking the first three kept the three the answer leans on least.
        let sources = (1 ... 5).map { Self.source($0, priority: 5 - $0) }
        #expect(AskSource.best(sources, limit: 3).map(\.ordinal) == [3, 4, 5])
        // Cited order, not rank order. The citations arrive in the order the
        // prose used them, and sorting the chips by rank would put the third
        // sentence's excerpt in front of the first's.
        #expect(AskSource.best(sources, limit: 3).map(\.priority) == [2, 1, 0])

        // An excerpt the ranker never scored — the `searchBook` tool's — sorts
        // behind every excerpt that has a rank rather than in front of them.
        // Cited first, so its position cannot be what saves the ranked five.
        let withTool = [Self.source(6, priority: nil)] + sources
        #expect(AskSource.best(withTool, limit: 3).map(\.ordinal) == [3, 4, 5])
        #expect(AskSource.best(withTool, limit: 5).map(\.ordinal) == [1, 2, 3, 4, 5])

        // Nothing to choose between: the input, untouched.
        let two = Array(sources.prefix(2))
        #expect(AskSource.best(two, limit: 3) == two)
    }

    @Test("two excerpts of equal rank are separated by their ordinal, not by chance")
    func bestBreaksTiesOnTheOrdinal() {
        let tied = [3, 1, 2].map { Self.source($0, priority: 0) }
        #expect(AskSource.best(tied, limit: 2).map(\.ordinal) == [1, 2])
        // And two unranked excerpts are ordered the same way.
        let unranked = [3, 1, 2].map { Self.source($0, priority: nil) }
        #expect(AskSource.best(unranked, limit: 2).map(\.ordinal) == [1, 2])
    }

    @Test("resolving stamps each source with the rank of the passage it names")
    func resolvingCarriesThePriority() {
        let shown = Self.shown(3)
        let priorities = Dictionary(uniqueKeysWithValues: (1 ... 3).map { (shown[$0]!, 3 - $0) })
        let answer = AskAnswerParser.resolving(
            AskAnswer(text: "She fell.", citations: [3, 1], notYetRevealed: false),
            among: shown, priorities: priorities,
        )
        #expect(answer.sources.map(\.priority) == [0, 2])
        // A passage the ranker never saw carries nothing rather than a zero,
        // which would make a tool excerpt the strongest thing in the row.
        let unranked = AskAnswerParser.resolving(
            AskAnswer(text: "She fell.", citations: [2], notYetRevealed: false),
            among: shown,
        )
        #expect(unranked.sources.map(\.priority) == [nil])
    }

    // MARK: - Where the answer came from

    @Test("the sentinel discloses nothing, because nothing was generated")
    func sentinelIsWithheld() {
        // The pill under it said "Generated on device · Apple Intelligence" for
        // a sentence that is a constant in this file.
        #expect(AskAnswerParser.parse("The story hasn't revealed that yet.").origin == .withheld)
        #expect(AskAnswerParser.parse("Alice met a rabbit.").origin == .model)
    }

    // MARK: - The sentinel

    @Test("the not-yet sentence is recognised however the model punctuates it")
    func recognisesTheSentinel() {
        // A 3B model reliably produces the sentence and unreliably produces its
        // punctuation. A strict match shows it as an ordinary answer, losing the
        // one state the reader most needs to see.
        for variant in [
            "The story hasn't revealed that yet.",
            "The story hasn’t revealed that yet",
            "The story has not revealed that yet.",
            "The story hasn't revealed that yet.\nSources:",
        ] {
            #expect(AskAnswerParser.parse(variant).notYetRevealed, "\(variant)")
        }
    }

    @Test("an ordinary answer is not mistaken for the sentinel")
    func doesNotOverMatch() {
        #expect(!AskAnswerParser.parse("The story is about a girl and a rabbit.").notYetRevealed)
        #expect(!AskAnswerParser.parse("").notYetRevealed)
    }

    // MARK: - Streaming

    @Test("a half-typed Sources line never reaches the screen")
    func withholdsAPartialFooter() {
        // The stream passes through every prefix of "Sources: 1, 3" on its way
        // there, and showing them flickers a half-typed footer under the answer.
        let answer = "Alice follows a rabbit."
        for tail in ["S", "So", "Sour", "Sources", "Sources:", "Sources: 1", "Sources: 1, 3"] {
            #expect(AskAnswerParser.visible("\(answer)\n\(tail)") == answer, "\(tail)")
        }
    }

    @Test("prose that merely starts with an S is shown")
    func showsOrdinaryProse() {
        #expect(AskAnswerParser.visible("Alice fell.\nShe landed softly.") == "Alice fell.\nShe landed softly.")
        #expect(AskAnswerParser.visible("Alice fell.") == "Alice fell.")
    }

    @Test("a stream that has only begun the footer shows nothing yet")
    func withholdsALoneFragment() {
        #expect(AskAnswerParser.visible("Sou") == "")
        #expect(AskAnswerParser.visible("") == "")
    }

    @Test("every prefix of a real answer is safe to show")
    func everyPrefixIsSafe() {
        let raw = "Alice follows a white rabbit down a hole.\nSources: 1, 2"
        var seen: [String] = []
        for length in 1 ... raw.count {
            let visible = AskAnswerParser.visible(String(raw.prefix(length)))
            seen.append(visible)
            #expect(!visible.lowercased().contains("sources:"), "at \(length)")
        }
        // And what is finally shown is the answer without its footer.
        #expect(seen.last == "Alice follows a white rabbit down a hole.")
    }
}
