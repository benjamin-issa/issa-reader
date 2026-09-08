import Foundation
import Testing

@testable import IssaAsk

struct PassageRankerTests {
    /// A candidate with the bm25 SQLite would have given it — negative, and
    /// better the lower it is.
    static func candidate(
        spine: Int, ordinal: Int, text: String, bm25: Double,
    ) -> RetrievedPassage {
        RetrievedPassage(
            passage: Passage(
                spineIndex: spine, ordinal: ordinal, start: ordinal * 500,
                end: ordinal * 500 + 400, words: PassageChunker.wordCount(text), text: text,
            ),
            bm25: bm25,
            isTruncated: false,
        )
    }

    @Test("a passage where two named people appear together beats a better bm25")
    func coOccurrenceBeatsBM25() {
        // The question is answered by the one paragraph where both are present.
        // BM25 will happily rank six paragraphs that say "Alice" forty times
        // above the single paragraph that says "Alice" and "Dinah" once each.
        let terms = QueryTerms.extract(
            from: "How does Alice know Dinah?", knownNames: ["Alice", "Dinah"],
        )
        // SQLite's bm25 is negative and better the lower it is, so this one
        // has the stronger term match of the two.
        let repetitive = Self.candidate(
            spine: 2, ordinal: 0, text: String(repeating: "Alice ", count: 40), bm25: -4,
        )
        let together = Self.candidate(
            spine: 2, ordinal: 1, text: "Alice thought of Dinah, her cat, and sighed.", bm25: -2,
        )
        let ranked = PassageRanker.rank([repetitive, together], terms: terms, limit: 2)
        #expect(ranked.count == 2)
        #expect(
            PassageRanker.score(together, terms: terms, isRecent: false)
                > PassageRanker.score(repetitive, terms: terms, isRecent: false),
        )
    }

    @Test("a passage carrying a whole kinship group is rewarded")
    func kinshipGroupsScore() {
        let terms = QueryTerms.extract(from: "Who is her cousin?")
        let related = Self.candidate(
            spine: 1, ordinal: 0, text: "Her family had one relative left in the north.", bm25: -1,
        )
        let unrelated = Self.candidate(
            spine: 1, ordinal: 1, text: "The garden gate was painted green.", bm25: -1,
        )
        let gap = PassageRanker.score(related, terms: terms, isRecent: false)
            - PassageRanker.score(unrelated, terms: terms, isRecent: false)
        #expect(abs(gap - PassageRanker.Weights.kinship) < 0.000_001)
    }

    @Test("the survivors come back in book order, not in score order")
    func restoresBookOrder() {
        // The instructions tell the model the excerpts are in reading order,
        // and a model handed events out of sequence invents a chronology to
        // explain them.
        let terms = QueryTerms.extract(from: "What did the rabbit say?")
        let candidates = [
            Self.candidate(spine: 5, ordinal: 2, text: "rabbit rabbit rabbit", bm25: -9),
            Self.candidate(spine: 2, ordinal: 7, text: "rabbit rabbit", bm25: -5),
            Self.candidate(spine: 2, ordinal: 1, text: "rabbit", bm25: -1),
        ]
        let ranked = PassageRanker.rank(candidates, terms: terms, limit: 3)
        #expect(ranked.map { ($0.passage.spineIndex, $0.passage.ordinal) }.map(\.0) == [2, 2, 5])
        #expect(ranked.map(\.passage.ordinal) == [1, 7, 2])
    }

    @Test("the limit takes the best, not the first")
    func limitTakesTheBest() {
        let terms = QueryTerms.extract(from: "What did the rabbit say?")
        let candidates = (0 ..< 10).map {
            Self.candidate(spine: 2, ordinal: $0, text: "rabbit", bm25: Double($0) * -1)
        }
        let ranked = PassageRanker.rank(candidates, terms: terms, limit: 3)
        // Ordinals 7, 8 and 9 have the lowest (best) bm25; recency is a flat
        // bonus over the same window, so it cannot reorder them.
        #expect(ranked.map(\.passage.ordinal) == [7, 8, 9])
    }

    @Test("recency breaks a tie but never buries a better match")
    func recencyIsSmall() {
        let terms = QueryTerms.extract(from: "What did the rabbit say?")
        // Ten equally good candidates: the recency window covers the last eight,
        // so the earliest two miss the bonus.
        var candidates = (1 ... 10).map {
            Self.candidate(spine: $0, ordinal: 0, text: "rabbit", bm25: -2)
        }
        #expect(PassageRanker.rank(candidates, terms: terms, limit: 1)
            .first?.passage.spineIndex == 3)

        // A reader almost always asks about what they have just read, but a
        // large bonus would bury the one early paragraph that introduced a
        // character — which is the answer to half the questions asked.
        #expect(PassageRanker.Weights.recency < PassageRanker.Weights.coOccurrence)
        candidates[0] = Self.candidate(spine: 1, ordinal: 0, text: "rabbit", bm25: -2.6)
        #expect(PassageRanker.rank(candidates, terms: terms, limit: 1)
            .first?.passage.spineIndex == 1)
    }

    @Test("no candidates ranks to nothing rather than trapping")
    func handlesEmpty() {
        #expect(PassageRanker.rank([], terms: QueryTerms.extract(from: "x"), limit: 6).isEmpty)
    }

    // MARK: - Priority

    @Test("the place a passage came in the score sort survives the book-order sort")
    func rankRecordsItsPriority() {
        let terms = QueryTerms.extract(from: "What did the rabbit say?")
        let candidates = [
            // Best bm25 last in the book, worst first, so book order and rank
            // order disagree about everything.
            Self.candidate(spine: 2, ordinal: 0, text: "rabbit", bm25: -1),
            Self.candidate(spine: 2, ordinal: 1, text: "rabbit", bm25: -3),
            Self.candidate(spine: 5, ordinal: 0, text: "rabbit", bm25: -9),
        ]
        let ranked = PassageRanker.rank(candidates, terms: terms, limit: 3)
        // Reading order for the model…
        #expect(ranked.map { ($0.passage.spineIndex, $0.passage.ordinal) }
            .elementsEqual([(2, 0), (2, 1), (5, 0)], by: ==))
        // …and the ranking written down beside it, which the second sort used
        // to throw away. `score` was identically zero everywhere downstream
        // because of it, and sorting on it was a provable no-op.
        #expect(ranked.map(\.priority) == [2, 1, 0])
    }

    @Test("best keeps the order it was given, sentence windows and all")
    func bestKeepsReadingOrder() {
        // Two sentence windows out of one paragraph. `order` is
        // `(spineIndex, ordinal)`, so these two are indistinguishable to it —
        // only `start` separates them, which is why `inBookOrder` sorts on
        // that instead.
        func window(start: Int, priority: Int) -> PassageRanker.Ranked {
            PassageRanker.Ranked(
                retrieved: RetrievedPassage(
                    passage: Passage(
                        spineIndex: 3, ordinal: 4, start: start, end: start + 20,
                        words: 4, text: "a window at \(start)",
                    ),
                    bm25: -1, isTruncated: false,
                ),
                priority: priority,
            )
        }
        let ranked = [
            window(start: 100, priority: 1),
            window(start: 140, priority: 0),
            window(start: 180, priority: 2),
        ]
        // A filter, never a re-sort: `Array.sorted` is not stable, so re-sorting
        // on `order` could hand the model one paragraph's sentences backwards,
        // and no other test in the suite would notice.
        #expect(PassageRanker.best(ranked, count: 2).map(\.passage.start) == [100, 140])
        #expect(PassageRanker.best(ranked, count: 3) == ranked)
        // Nested — every smaller answer is a subset of the larger one, which is
        // what keeps the retry ladder shrinking the prompt rather than
        // shuffling it into a different prompt of the same size.
        for count in 0 ... 3 {
            let smaller = Set(PassageRanker.best(ranked, count: count))
            #expect(smaller.isSubset(of: Set(PassageRanker.best(ranked, count: count + 1))))
        }
    }
}
