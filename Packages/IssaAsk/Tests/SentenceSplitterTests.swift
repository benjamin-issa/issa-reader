import Foundation
import Testing

@testable import IssaAsk

/// The splitter that decides what one piece of evidence is.
struct SentenceSplitterTests {
    static func pieces(_ text: String) -> [String] {
        let string = text as NSString
        return SentenceSplitter.ranges(in: text).map { string.substring(with: $0) }
    }

    @Test("an honorific does not end a sentence")
    func mergesHonorifics() {
        // ICU cuts "Mr. Rabbit ran." after "Mr.", which turns the sentence that
        // introduces a character into a two-word fragment predicating nothing —
        // and hands the model half a thought with a citation on it.
        #expect(Self.pieces("Mr. Rabbit ran home. Alice followed.")
            == ["Mr. Rabbit ran home. ", "Alice followed."])
        #expect(Self.pieces("Dr. Watson was there. He said nothing.")
            == ["Dr. Watson was there. ", "He said nothing."])
        // An initial is the same problem with a different abbreviation.
        #expect(Self.pieces("T. Rabbit arrived late. Nobody minded.")
            == ["T. Rabbit arrived late. ", "Nobody minded."])
    }

    @Test("a runt with no full stop joins what follows")
    func mergesFragments() {
        #expect(Self.pieces("CHAPTER I\nAlice was tired of the bank.")
            == ["CHAPTER I\nAlice was tired of the bank."])
        // …but a short *terminated* sentence is a sentence.
        #expect(Self.pieces("She wept. Alice was tired of sitting there.")
            == ["She wept. ", "Alice was tired of sitting there."])
    }

    @Test("a parenthetical stays with its sentence")
    func keepsParentheticals() {
        let pieces = Self.pieces("“Dinah’ll miss me!” (Dinah was the cat.) She sighed.")
        #expect(pieces.count == 3)
        #expect(pieces[1].contains("Dinah was the cat"))
    }

    @Test("the ranges tile the passage with no gaps")
    func tilesWithoutGaps() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let string = text as NSString
        let window = NSRange(location: 200, length: 4_000)
        let ranges = SentenceSplitter.ranges(in: string, range: window)
        try #require(ranges.count > 1)

        // A gap is a few characters of the book that no evidence window can
        // ever show — including, at the end, the punctuation that says the
        // sentence finished.
        #expect(ranges.first?.location == window.location)
        #expect(NSMaxRange(try #require(ranges.last)) == NSMaxRange(window))
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            #expect(NSMaxRange(previous) == next.location)
        }
        // And joining them back up gives the passage, character for character.
        let rejoined = ranges.map { string.substring(with: $0) }.joined()
        #expect(rejoined == string.substring(with: window))
    }

    @Test("an empty or impossible range yields nothing rather than trapping")
    func handlesDegenerateRanges() {
        let string = "Alice." as NSString
        #expect(SentenceSplitter.ranges(in: string, range: NSRange(location: 0, length: 0)).isEmpty)
        #expect(SentenceSplitter.ranges(
            in: string, range: NSRange(location: 0, length: 99),
        ).isEmpty)
        #expect(SentenceSplitter.ranges(in: "").isEmpty)
    }

    @Test("the real book splits into sentences that are actually sentences")
    func splitsTheFixture() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let string = text as NSString
        let ranges = SentenceSplitter.ranges(in: text)
        let sentences = ranges.map {
            string.substring(with: $0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let opening = try #require(sentences.first { $0.contains("sitting by her sister") })
        #expect(opening.hasPrefix("CHAPTER I") || opening.hasPrefix("Alice was beginning"))
        // Nothing that is nothing: every piece has a word in it.
        #expect(sentences.allSatisfy { !$0.isEmpty })
    }
}
