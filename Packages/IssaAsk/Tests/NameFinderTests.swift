import Foundation
import Testing

@testable import IssaAsk

/// Who the book thinks its people are.
///
/// The name table is not decoration: it is what promotes a token `NLTagger`
/// never tags — "Cheshire", "Vin", "Duchess" — into the subject a question is
/// retrieved by. A character who falls out of it is a question answered from
/// the wrong paragraphs.
struct NameFinderTests {
    @Test("two spellings of one person share a key")
    func foldsCaseAndDiacritics() {
        #expect(NameFinder.Name.key(for: "VIN") == NameFinder.Name.key(for: "Vin"))
        #expect(NameFinder.Name.key(for: "Brontë") == NameFinder.Name.key(for: "Bronte"))
        #expect(NameFinder.Name.key(for: "Vin") != NameFinder.Name.key(for: "Vinn"))
    }

    @Test("merging pools the spellings and keeps the earliest sighting")
    func mergePoolsOnTheKey() {
        let merged = NameFinder.merge([
            NameFinder.Name(name: "VIN", spineIndex: 3, firstOffset: 100, mentions: 40),
            NameFinder.Name(name: "Vin", spineIndex: 1, firstOffset: 20, mentions: 90),
            NameFinder.Name(name: "Vin", spineIndex: 4, firstOffset: 0, mentions: 10),
            NameFinder.Name(name: "Elend", spineIndex: 2, firstOffset: 5, mentions: 100),
        ])
        #expect(merged.map(\.name) == ["Vin", "Elend"])
        #expect(merged.first?.mentions == 140)
        // The earliest sighting is what the boundary compares against, so a
        // later chapter's mention must never move it forward.
        #expect(merged.first?.spineIndex == 1)
        #expect(merged.first?.firstOffset == 20)
    }

    @Test("the order the chapters arrived in does not decide the spelling")
    func spellingIsNotOrderDependent() {
        let rows = [
            NameFinder.Name(name: "VIN", spineIndex: 0, firstOffset: 0, mentions: 30),
            NameFinder.Name(name: "VIN", spineIndex: 1, firstOffset: 0, mentions: 30),
            NameFinder.Name(name: "Vin", spineIndex: 2, firstOffset: 0, mentions: 70),
        ]
        // Folded a chapter at a time, the incumbent's running total would beat
        // the challenger's single chapter and the shout would win.
        #expect(NameFinder.merge(rows).first?.name == "Vin")
        #expect(NameFinder.merge(rows.reversed()).first?.name == "Vin")
    }

    @Test("a tie goes to the spelling that is not shouting")
    func prefersTheQuietSpelling() {
        #expect(NameFinder.prefers("Vin", over: "VIN", mentions: 10, against: 10))
        #expect(!NameFinder.prefers("VIN", over: "Vin", mentions: 10, against: 10))
        // Counts still come first: a book that really does print the capitals
        // more often is printing the character's name.
        #expect(NameFinder.prefers("VIN", over: "Vin", mentions: 30, against: 10))
        #expect(!NameFinder.isAllCaps("Vin"))
        #expect(NameFinder.isAllCaps("VIN"))
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
