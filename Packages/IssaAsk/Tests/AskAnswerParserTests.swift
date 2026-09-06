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
