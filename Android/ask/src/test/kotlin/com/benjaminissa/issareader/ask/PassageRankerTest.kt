package com.benjaminissa.issareader.ask

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class PassageRankerTest {
    /** A candidate with the bm25 SQLite would have given it — negative, and better the lower it is. */
    private fun candidate(spine: Int, ordinal: Int, text: String, bm25: Double): RetrievedPassage = RetrievedPassage(
        Passage(
            spineIndex = spine, ordinal = ordinal, start = ordinal * 500, end = ordinal * 500 + 400,
            words = PassageChunker.wordCount(text), text = text,
        ),
        bm25 = bm25, isTruncated = false,
    )

    @Test
    fun `a passage where two named people appear together beats a better bm25`() {
        val terms = QueryTerms.extract("How does Alice know Dinah?", knownNames = listOf("Alice", "Dinah"))
        val repetitive = candidate(spine = 2, ordinal = 0, text = "Alice ".repeat(40), bm25 = -4.0)
        val together = candidate(spine = 2, ordinal = 1, text = "Alice thought of Dinah, her cat, and sighed.", bm25 = -2.0)
        val ranked = PassageRanker.rank(listOf(repetitive, together), terms, limit = 2)
        assertEquals(2, ranked.size)
        assertTrue(PassageRanker.score(together, terms, isRecent = false) > PassageRanker.score(repetitive, terms, isRecent = false))
    }

    @Test
    fun `a passage carrying a whole kinship group is rewarded`() {
        val terms = QueryTerms.extract("Who is her cousin?")
        val related = candidate(spine = 1, ordinal = 0, text = "Her family had one relative left in the north.", bm25 = -1.0)
        val unrelated = candidate(spine = 1, ordinal = 1, text = "The garden gate was painted green.", bm25 = -1.0)
        val gap = PassageRanker.score(related, terms, isRecent = false) - PassageRanker.score(unrelated, terms, isRecent = false)
        assertTrue(abs(gap - PassageRanker.Weights.kinship) < 0.000_001)
    }

    @Test
    fun `the survivors come back in book order, not in score order`() {
        val terms = QueryTerms.extract("What did the rabbit say?")
        val candidates = listOf(
            candidate(spine = 5, ordinal = 2, text = "rabbit rabbit rabbit", bm25 = -9.0),
            candidate(spine = 2, ordinal = 7, text = "rabbit rabbit", bm25 = -5.0),
            candidate(spine = 2, ordinal = 1, text = "rabbit", bm25 = -1.0),
        )
        val ranked = PassageRanker.rank(candidates, terms, limit = 3)
        assertEquals(listOf(2, 2, 5), ranked.map { it.passage.spineIndex })
        assertEquals(listOf(1, 7, 2), ranked.map { it.passage.ordinal })
    }

    @Test
    fun `the limit takes the best, not the first`() {
        val terms = QueryTerms.extract("What did the rabbit say?")
        val candidates = (0 until 10).map { candidate(spine = 2, ordinal = it, text = "rabbit", bm25 = it * -1.0) }
        val ranked = PassageRanker.rank(candidates, terms, limit = 3)
        // Ordinals 7, 8 and 9 have the lowest (best) bm25; recency is a flat
        // bonus over the same window, so it cannot reorder them.
        assertEquals(listOf(7, 8, 9), ranked.map { it.passage.ordinal })
    }

    @Test
    fun `recency breaks a tie but never buries a better match`() {
        val terms = QueryTerms.extract("What did the rabbit say?")
        // Ten equally good candidates: the recency window covers the last
        // eight, so the earliest two miss the bonus.
        val candidates = (1..10).map { candidate(spine = it, ordinal = 0, text = "rabbit", bm25 = -2.0) }.toMutableList()
        assertEquals(3, PassageRanker.rank(candidates, terms, limit = 1).first().passage.spineIndex)

        // A large bonus would bury the one early paragraph that introduced a
        // character.
        assertTrue(PassageRanker.Weights.recency < PassageRanker.Weights.coOccurrence)
        candidates[0] = candidate(spine = 1, ordinal = 0, text = "rabbit", bm25 = -2.6)
        assertEquals(1, PassageRanker.rank(candidates, terms, limit = 1).first().passage.spineIndex)
    }

    @Test
    fun `no candidates ranks to nothing rather than trapping`() {
        assertTrue(PassageRanker.rank(emptyList(), QueryTerms.extract("x"), limit = 6).isEmpty())
    }

    // Priority

    @Test
    fun `the place a passage came in the score sort survives the book-order sort`() {
        val terms = QueryTerms.extract("What did the rabbit say?")
        val candidates = listOf(
            // Best bm25 last in the book, worst first, so book order and rank
            // order disagree about everything.
            candidate(spine = 2, ordinal = 0, text = "rabbit", bm25 = -1.0),
            candidate(spine = 2, ordinal = 1, text = "rabbit", bm25 = -3.0),
            candidate(spine = 5, ordinal = 0, text = "rabbit", bm25 = -9.0),
        )
        val ranked = PassageRanker.rank(candidates, terms, limit = 3)
        // Reading order for the model…
        assertEquals(listOf(2 to 0, 2 to 1, 5 to 0), ranked.map { it.passage.spineIndex to it.passage.ordinal })
        // …and the ranking written down beside it.
        assertEquals(listOf(2, 1, 0), ranked.map { it.priority })
    }

    @Test
    fun `best keeps the order it was given, sentence windows and all`() {
        fun window(start: Int, priority: Int) = PassageRanker.Ranked(
            RetrievedPassage(
                Passage(spineIndex = 3, ordinal = 4, start = start, end = start + 20, words = 4, text = "a window at $start"),
                bm25 = -1.0, isTruncated = false,
            ),
            priority = priority,
        )
        val ranked = listOf(window(start = 100, priority = 1), window(start = 140, priority = 0), window(start = 180, priority = 2))
        // A filter, never a re-sort.
        assertEquals(listOf(100, 140), PassageRanker.best(ranked, 2).map { it.passage.start })
        assertEquals(ranked, PassageRanker.best(ranked, 3))
        // Nested — every smaller answer is a subset of the larger one.
        for (count in 0..3) {
            val smaller = PassageRanker.best(ranked, count).toSet()
            assertTrue(PassageRanker.best(ranked, count + 1).toSet().containsAll(smaller))
        }
    }
}
