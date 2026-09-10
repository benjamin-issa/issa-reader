import Foundation
import Testing

@testable import IssaAsk

/// The chips under the question field, which used to be two.
///
/// Two was the whole of what the feature said it could do, and the second was
/// always the recap — so a reader learned that Ask answers "Who is X?" and
/// summarises. Six chips are only an improvement if they are six *different*
/// questions: six spellings of "Who is X?" would say exactly as little, and
/// would say it at three times the height.
///
/// The wording is asserted rather than described, because the wording decides
/// which retrieval a chip gets and the near misses are bad. "What is Alice
/// like?" classifies as an identity question with `like` in the subject, so
/// every passage would have to contain the word.
@Suite("The suggestion chips")
struct AskSuggestionsTests {
    static let names = ["Alice", "Dinah", "Mary Ann"]

    @Test("six chips take six different paths through retrieval")
    func chipsAreDifferentQuestions() {
        let chips = AskSuggestions.chips(topNames: Self.names)
        #expect(chips.count == 6)
        // One `Set` of kinds, not six labels compared by eye. Every kind the
        // engine has appears, and no kind appears more than twice.
        var counts: [String: Int] = [:]
        for chip in chips {
            counts[QueryTerms.extract(from: chip, knownNames: Self.names).kind.label,
                   default: 0] += 1
        }
        #expect(Set(counts.keys) == ["identity", "kinship", "general", "recap"])
        #expect(counts.values.allSatisfy { $0 <= 2 }, "\(counts)")
    }

    @Test("the two chips that shipped are still the first two, unchanged")
    func keepsTheOriginalPair() {
        let chips = AskSuggestions.chips(topNames: Self.names)
        // A reader who has used this before should not have to find the recap
        // again because four more capsules arrived above it.
        #expect(chips[0] == "Who is Alice?")
        #expect(chips[1] == AskSuggestions.recap)
    }

    @Test("every chip names only somebody the index handed over")
    func namesStayBounded() {
        // The whole spoiler defence is that a chip cannot name anybody the
        // reader has not met, because the only names it has are the ones
        // `topNames(before:)` returned for this position.
        for chip in AskSuggestions.chips(topNames: ["Alice", "Dinah"]) {
            #expect(!chip.contains("Mary Ann"))
            #expect(!chip.contains("Cheshire"))
        }
    }

    // MARK: - Degrading

    @Test("a book that has introduced nobody still offers two sensible chips")
    func noNames() {
        #expect(AskSuggestions.chips(topNames: []) == [
            AskSuggestions.fallbackName, AskSuggestions.recap,
        ])
    }

    @Test("one name gives five real chips rather than six with a hole in one")
    func oneName() {
        let chips = AskSuggestions.chips(topNames: ["Alice"])
        // The second identity chip is the only one that needs a second name,
        // and a book with one character must not be offered "Who is ?".
        #expect(chips.count == 5)
        #expect(chips.allSatisfy { !$0.contains("  ") && !$0.contains(" ?") })
        #expect(!chips.contains { $0 == "Who is ?" })
    }

    @Test("nothing the index calls a name is printed unless it looks like one")
    func rejectsUnprintableNames() {
        // Real rows from *Alice*'s own index. `NLTagger` runs a name into the
        // words after it — "Alice soon began talking again" — and offering
        // "Who is Alice soon began?" makes the feature look broken before it
        // has answered anything.
        #expect(!AskSuggestions.isPresentable("Alice soon began"))
        #expect(!AskSuggestions.isPresentable("said the Duchess"))
        #expect(!AskSuggestions.isPresentable(""))
        #expect(AskSuggestions.isPresentable("Alice"))
        #expect(AskSuggestions.isPresentable("White Rabbit"))
        #expect(AskSuggestions.isPresentable("Mary Ann"))
        // Skipped rather than fatal: the first *presentable* name wins.
        #expect(AskSuggestions.chips(topNames: ["Alice soon began", "Alice"])[0]
            == "Who is Alice?")
    }
}
