import Foundation
import Testing

@testable import IssaAsk

struct PassageChunkerTests {
    // MARK: - Tiling

    @Test("passages tile the chapter with no gaps and no overlaps")
    func tilesWithoutGaps() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let passages = PassageChunker.chunk(text: text, spineIndex: AskFixture.Spine.chapterI)
        try #require(passages.count > 3)

        // The straddling passage is cut to `boundary.charOffset - start`. A gap
        // anywhere in this sequence is a hole the reader's position can fall
        // into, and the sentence being read aloud would vanish from retrieval.
        #expect(passages.first?.start == 0)
        #expect(passages.last?.end == (text as NSString).length)
        for (earlier, later) in zip(passages, passages.dropFirst()) {
            #expect(earlier.end == later.start)
        }
    }

    @Test("ordinals are the passage's own position, in order")
    func ordinalsAreSequential() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterII)
        let passages = PassageChunker.chunk(text: text, spineIndex: AskFixture.Spine.chapterII)
        #expect(passages.map(\.ordinal) == Array(passages.indices))
        #expect(passages.allSatisfy { $0.spineIndex == AskFixture.Spine.chapterII })
    }

    @Test("a passage's characters are the chapter's characters from its start")
    func textMatchesItsOffsets() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        let string = text as NSString
        for passage in PassageChunker.chunk(text: text, spineIndex: AskFixture.Spine.chapterI) {
            // Not trimmed at the front, deliberately: character *i* of the
            // stored text has to be chapter offset `start + i` or the
            // straddling cut lands a word into the next sentence.
            let slice = string.substring(with: passage.range)
            #expect(slice.hasPrefix(passage.text))
        }
    }

    // MARK: - Limits

    @Test("no passage exceeds the maximum, except one that cannot be split")
    func respectsMaximum() throws {
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterVI)
        let passages = PassageChunker.chunk(text: text, spineIndex: AskFixture.Spine.chapterVI)
        // A single sentence longer than the maximum has nowhere to be cut, so
        // the limit is a target for the splitter, not a guarantee. What must
        // hold is that the splitter actually ran: the great majority fit.
        let oversized = passages.filter { $0.words > PassageChunker.Limits.maximumWords }
        #expect(Double(oversized.count) / Double(passages.count) < 0.1)
    }

    @Test("a long paragraph is split at sentence ends, not mid-sentence")
    func splitsAtSentences() {
        let sentence = "She ran down the passage and found a very small door behind a curtain. "
        let paragraph = String(repeating: sentence, count: 12)
        let passages = PassageChunker.chunk(text: paragraph, spineIndex: 0)
        #expect(passages.count > 1)
        // Every piece but the last ends where a sentence ends. A naive full-stop
        // scan gets "Mr." wrong; this is why the splitter enumerates sentences.
        for passage in passages.dropLast() {
            let trimmed = passage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed.hasSuffix("."))
        }
    }

    @Test("a runt is merged into its neighbour rather than retrieved alone")
    func mergesRunts() {
        let body = String(repeating: "The garden was full of bright flowers and cool fountains. ", count: 12)
        let text = "CHAPTER I\n\"Oh dear!\"\n\(body)"
        let passages = PassageChunker.chunk(text: text, spineIndex: 0)
        // A line of dialogue on its own tells the model nothing about who said
        // it, and a heading on its own is not evidence of anything.
        #expect(passages.allSatisfy { $0.words >= PassageChunker.Limits.minimumWords })
        #expect(passages[0].text.contains("CHAPTER I"))
    }

    @Test("a chapter opening on a heading keeps the heading with its first paragraph")
    func mergesLeadingHeading() {
        let body = String(repeating: "Alice was beginning to get very tired of sitting by her sister. ", count: 10)
        let passages = PassageChunker.chunk(text: "CHAPTER I. Down the Rabbit-Hole\n\(body)", spineIndex: 0)
        #expect(passages.count == 1)
        #expect(passages[0].start == 0)
    }

    // MARK: - Degenerate input

    @Test("empty and whitespace-only chapters produce nothing")
    func handlesEmptyChapters() {
        #expect(PassageChunker.chunk(text: "", spineIndex: 0).isEmpty)
        #expect(PassageChunker.chunk(text: "\n\n  \n", spineIndex: 0).isEmpty)
    }

    @Test("words are counted by whitespace runs")
    func countsWords() {
        #expect(PassageChunker.wordCount("") == 0)
        #expect(PassageChunker.wordCount("   ") == 0)
        #expect(PassageChunker.wordCount("one two  three\nfour") == 4)
    }

    // MARK: - Navigation

    /// Verified on the simulator: "Who is Alice?" asked at 4% cited "CHAPTER
    /// XII. Alice's Evidence". Not a boundary leak — the contents table sits at
    /// the front of the spine and is legitimately behind the reader — but a
    /// list of chapter titles is not evidence, and citing one makes the whole
    /// feature look broken.
    @Test("the contents table is not indexed, and neither is Gutenberg's wrapper")
    func dropsTheContentsList() throws {
        let package = try AskFixture.package()
        let titles = package.navigation.map(\.title)
        var dropped: [Passage] = []
        var keptSpines: Set<Int> = []
        for spine in package.spine.indices {
            let text = try AskFixture.text(spine: spine)
            let all = PassageChunker.chunk(text: text, spineIndex: spine)
            let kept = PassageChunker.indexable(
                text: text, spineIndex: spine, navigationTitles: titles,
            )
            dropped.append(contentsOf: all.filter { !kept.contains($0) })
            if !kept.isEmpty { keptSpines.insert(spine) }
        }
        // The contents table, which lives on Gutenberg's header page rather
        // than in the nav document…
        #expect(dropped.contains { $0.spineIndex == 1 && $0.text.contains("CHAPTER XII") })
        // …the legal notice and credits above the START marker on that page…
        #expect(dropped.contains { $0.spineIndex == 1 && $0.text.contains("David Widger") })
        // …and the whole licence chapter below the END marker.
        #expect(!keptSpines.contains(1))
        #expect(!keptSpines.contains(package.spine.count - 1))
        // Nothing else. Every chapter of the story keeps every passage it had.
        #expect(dropped.allSatisfy { $0.spineIndex == 1 || $0.spineIndex == package.spine.count - 1 })
        // 0 is the SVG cover wrapper, which renders as one object-replacement
        // character and stays: it carries no marker and no navigation title, so
        // nothing here has an opinion about it, and one character of nothing
        // costs the index nothing either.
        #expect(keptSpines == Set(0 ... 13).subtracting([1]))
    }

    /// The gate that costs the most to get wrong. *Alice*'s contents table is
    /// 13 lines averaging 4.5 words and the Mouse's Tale is 46 lines averaging
    /// 3.0, so nothing about line length can tell them apart — which is why the
    /// book's own navigation titles decide and the shape only qualifies.
    @Test("a shaped poem of equally short lines is kept")
    func keepsAPoem() throws {
        let package = try AskFixture.package()
        let titles = package.navigation.map(\.title)
        // Chapter III, where "Fury said to a mouse" is set as a tail.
        let text = try AskFixture.text(spine: 4)
        let kept = PassageChunker.indexable(text: text, spineIndex: 4, navigationTitles: titles)
        #expect(kept.contains { $0.text.contains("Fury said to") })
        #expect(kept.count == PassageChunker.chunk(text: text, spineIndex: 4).count)
    }

    @Test("with no navigation and no marker to go on, nothing is dropped")
    func withoutTitlesNothingIsDropped() throws {
        // The navigation test is "these lines are the book's own section
        // titles", and a book that declares no contents has nothing to be sure
        // about — guessing from line shape alone is what would take the poem
        // with it. Chapter I rather than the header page, which Gutenberg's own
        // marker rules out whatever the navigation says.
        let text = try AskFixture.text(spine: AskFixture.Spine.chapterI)
        #expect(
            PassageChunker.indexable(text: text, spineIndex: AskFixture.Spine.chapterI).count
                == PassageChunker.chunk(text: text, spineIndex: AskFixture.Spine.chapterI).count,
        )
    }

    /// The credits line is the whole point: "Arthur DiBianca and David Widger"
    /// were tagged as people, counted in the name table, and offered as a
    /// suggestion chip beside the book's own protagonist.
    @Test("what Gutenberg marks as its own is outside the book")
    func gutenbergMarkersBoundTheBook() {
        let text = """
            The Project Gutenberg eBook of A Book
            Credits: David Widger
            *** START OF THE PROJECT GUTENBERG EBOOK A BOOK ***
            Alice was beginning to get very tired of sitting by her sister.
            *** END OF THE PROJECT GUTENBERG EBOOK A BOOK ***
            Updated editions will replace the previous one.
            """
        let range = PassageChunker.bookRange(in: text)
        let inside = (text as NSString).substring(with: range)
        #expect(inside.contains("Alice was beginning"))
        #expect(!inside.contains("David Widger"))
        #expect(!inside.contains("Updated editions"))
        // The older spelling, which is what most files on a shelf carry.
        #expect(PassageChunker.bookRange(
            in: "a\n*** START OF THIS PROJECT GUTENBERG EBOOK X ***\nb",
        ).location > 0)
        // A book with no marker keeps all of itself.
        let plain = "Just a chapter of prose, with no transcriber's wrapper."
        #expect(PassageChunker.bookRange(in: plain)
            == NSRange(location: 0, length: (plain as NSString).length))
    }

    @Test("a chapter heading above its own first paragraph is not a contents list")
    func aHeadingIsNotNavigation() {
        // Two of these three lines match a navigation entry, and the third is
        // the chapter. Both the short-line share and the floor of three matches
        // have to hold for this to survive.
        let body = String(repeating: "Alice was beginning to get very tired of sitting. ", count: 12)
        #expect(!PassageChunker.isNavigationList(
            "CHAPTER I.\nDown the Rabbit-Hole\n\(body)",
            titles: [["chapter", "i", "down", "the", "rabbit'hole"]],
        ))
    }

    @Test("a contents list whose titles are spelled differently is still caught")
    func matchesLooselyEnough() {
        // Gutenberg's NCX calls the chapter "I ANCESTRY AND EARLY YOUTH IN
        // BOSTON" and its own contents page prints "I. Ancestry and Early Life
        // in Boston" — *Youth* against *Life*. An equality test finds nothing
        // on the book this was measured against.
        let titles = [
            ["i", "ancestry", "and", "early", "youth", "in", "boston"],
            ["ii", "beginning", "life", "as", "a", "printer"],
            ["iii", "arrival", "in", "philadelphia"],
        ]
        #expect(PassageChunker.isNavigationList("""
            I.  Ancestry and Early Life in Boston
            3
            II.  Beginning Life as a Printer
            21
            III.  Arrival in Philadelphia
            41
            """, titles: titles))
    }
}
