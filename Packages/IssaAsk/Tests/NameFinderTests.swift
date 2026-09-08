import Foundation
import Testing

@testable import IssaAsk

/// Who the book thinks its people are.
///
/// The name table is not decoration: it is what promotes a token `NLTagger`
/// never tags — "Cheshire", "Ryn", "Duchess" — into the subject a question is
/// retrieved by. A character who falls out of it is a question answered from
/// the wrong paragraphs.
struct NameFinderTests {
    @Test("two spellings of one person share a key")
    func foldsCaseAndDiacritics() {
        #expect(NameFinder.Name.key(for: "RYN") == NameFinder.Name.key(for: "Ryn"))
        #expect(NameFinder.Name.key(for: "Brontë") == NameFinder.Name.key(for: "Bronte"))
        #expect(NameFinder.Name.key(for: "Ryn") != NameFinder.Name.key(for: "Rynn"))
    }

    @Test("merging pools the spellings and keeps the earliest sighting")
    func mergePoolsOnTheKey() {
        let merged = NameFinder.merge([
            NameFinder.Name(name: "RYN", spineIndex: 3, firstOffset: 100, mentions: 40),
            NameFinder.Name(name: "Ryn", spineIndex: 1, firstOffset: 20, mentions: 90),
            NameFinder.Name(name: "Ryn", spineIndex: 4, firstOffset: 0, mentions: 10),
            NameFinder.Name(name: "Marek", spineIndex: 2, firstOffset: 5, mentions: 100),
        ])
        #expect(merged.map(\.name) == ["Ryn", "Marek"])
        #expect(merged.first?.mentions == 140)
        // The earliest sighting is what the boundary compares against, so a
        // later chapter's mention must never move it forward.
        #expect(merged.first?.spineIndex == 1)
        #expect(merged.first?.firstOffset == 20)
    }

    @Test("the order the chapters arrived in does not decide the spelling")
    func spellingIsNotOrderDependent() {
        let rows = [
            NameFinder.Name(name: "RYN", spineIndex: 0, firstOffset: 0, mentions: 30),
            NameFinder.Name(name: "RYN", spineIndex: 1, firstOffset: 0, mentions: 30),
            NameFinder.Name(name: "Ryn", spineIndex: 2, firstOffset: 0, mentions: 70),
        ]
        // Folded a chapter at a time, the incumbent's running total would beat
        // the challenger's single chapter and the shout would win.
        #expect(NameFinder.merge(rows).first?.name == "Ryn")
        #expect(NameFinder.merge(rows.reversed()).first?.name == "Ryn")
    }

    /// Two spellings could not show this: the comparison only becomes a
    /// comparison against a *running total* from the third one onwards.
    ///
    /// Which is what made it non-deterministic across launches — the pooling
    /// walked an unordered `Dictionary.values`, and Swift seeds its hasher per
    /// process. Run eight times before the fix, five runs picked "BRONTE" for
    /// some orderings and three picked "Bronte" for all of them: a chapter
    /// heading offered as the name of a character, on some launches of the same
    /// build reading the same book.
    @Test("a third spelling cannot change which of the other two is shown")
    func spellingSurvivesAThirdVariant() {
        let rows = [
            NameFinder.Name(name: "BRONTE", spineIndex: 0, firstOffset: 0, mentions: 9),
            NameFinder.Name(name: "Bronte", spineIndex: 1, firstOffset: 0, mentions: 10),
            NameFinder.Name(name: "Brontë", spineIndex: 2, firstOffset: 0, mentions: 5),
        ]
        for order in Self.permutations(rows) {
            let merged = NameFinder.merge(order)
            // Ten beats nine beats five, whatever order they arrive in — and
            // "Brontë" folds in with them, because the index's own tokeniser
            // removes diacritics and a question about "Bronte" has to reach a
            // book that writes "Brontë".
            #expect(merged.count == 1, "\(order.map(\.name))")
            #expect(merged.first?.name == "Bronte", "\(order.map(\.name))")
            #expect(merged.first?.mentions == 24, "\(order.map(\.name))")
            // The earliest sighting is still the earliest of all three.
            #expect(merged.first?.spineIndex == 0, "\(order.map(\.name))")
        }
    }

    static func permutations(_ names: [NameFinder.Name]) -> [[NameFinder.Name]] {
        guard names.count > 1 else { return [names] }
        var out: [[NameFinder.Name]] = []
        for (index, name) in names.enumerated() {
            var rest = names
            rest.remove(at: index)
            for tail in permutations(rest) { out.append([name] + tail) }
        }
        return out
    }

    @Test("a tie goes to the spelling that is not shouting")
    func prefersTheQuietSpelling() {
        #expect(NameFinder.prefers("Ryn", over: "RYN", mentions: 10, against: 10))
        #expect(!NameFinder.prefers("RYN", over: "Ryn", mentions: 10, against: 10))
        // Counts still come first: a book that really does print the capitals
        // more often is printing the character's name.
        #expect(NameFinder.prefers("RYN", over: "Ryn", mentions: 30, against: 10))
        #expect(!NameFinder.isAllCaps("Ryn"))
        #expect(NameFinder.isAllCaps("RYN"))
        // "I" is a word, not a shout, but it is also not a name that gets here.
        #expect(!NameFinder.isAllCaps("123"))
    }

    @Test("an honorific does not make a second person")
    func stripsHonorifics() {
        #expect(NameFinder.normalise("Mr. Rabbit")?.display == "Rabbit")
        #expect(NameFinder.normalise("Mr. Rabbit")?.key == NameFinder.normalise("Rabbit")?.key)
        // …but an honorific on its own is not a name at all.
        #expect(NameFinder.normalise("Miss")?.display == "Miss")
        #expect(NameFinder.normalise("a")  == nil)
        #expect(NameFinder.normalise("rabbit") == nil, "a lowercase name is the tagger mis-firing")
    }

    @Test("the fixture's people are found, and its places are not")
    func findsPeopleInTheRealBook() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let names = NameFinder.merge(NameFinder.names(in: text, spineIndex: 2))
        #expect(names.contains { $0.name == "Alice" })
        // A capital-letter heuristic offers "Who is Chapter?" as a suggestion.
        #expect(!names.contains { $0.name.lowercased().contains("chapter") })
        #expect(!names.contains { $0.name.lowercased().contains("wonderland") })
    }
}
