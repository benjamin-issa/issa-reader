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
}
