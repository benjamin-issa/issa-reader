package com.benjaminissa.issareader.ask

/**
 * Chooses which passages the model actually sees.
 *
 * BM25 alone is not enough, and the reason is specific to fiction. A question
 * like "How is Alice related to her sister?" is answered by the paragraph where
 * both appear together, and BM25 will happily rank six paragraphs that mention
 * Alice forty times each above the one paragraph that mentions both once. So
 * co-occurrence of *distinct* names is rewarded outright, and a passage
 * containing a whole kinship group is rewarded again — those are the two
 * signals that separate "about this" from "contains this word".
 *
 * The recency bonus is small and deliberate: a reader almost always asks about
 * what they have just read, but "almost always" is not "always", and a large
 * bonus would bury the one early paragraph that introduced a character.
 */
object PassageRanker {
    /** The weights, in one place so a test asserts against the shipped numbers. */
    object Weights {
        /** Per distinct question-name beyond the first that a passage contains. */
        const val coOccurrence = 2.5

        /** Per kinship group the passage has a member of. */
        const val kinship = 0.6

        /** Flat bonus for being among the last passages before the boundary. */
        const val recency = 0.5

        /** How many passages count as "recent". */
        const val recentWindow = 8
    }

    /**
     * A passage and how badly the question wants it, for the trimming and the
     * retry ladder to sacrifice the right ones.
     *
     * An ordinal rather than a score, and zero is best. Two finders' numbers
     * meet in one list at the kinship top-up, and a BM25-derived score there
     * would let a book's term statistics decide that a context paragraph
     * outranks the kinship sentence it was context for.
     */
    data class Ranked(
        val retrieved: RetrievedPassage,
        /**
         * Position among the passages this question retrieved. Required at
         * every call site on purpose: this replaced a `score` that was
         * identically zero on every production path, and a path that forgets
         * to stamp it should fail to compile rather than quietly revert to
         * book order.
         */
        val priority: Int,
    ) {
        val passage: Passage get() = retrieved.passage
    }

    /**
     * Scores, takes the best [limit], and puts them back into book order —
     * keeping the permutation it computed on the way.
     *
     * Book order matters to the answer, not to the retrieval: the model is told
     * the excerpts are in reading order, and a model handed events out of
     * sequence invents a chronology to explain them. But the place a passage
     * came in the score sort is written down as its `priority`, so the
     * trimming and the retry ladder have something to go on but position.
     */
    fun rank(candidates: List<RetrievedPassage>, terms: QueryTerms, limit: Int = 6): List<Ranked> {
        if (candidates.isEmpty()) return emptyList()
        val recentCutoff = recencyCutoff(candidates)
        val scored = candidates.map { it to score(it, terms, isRecent(it, recentCutoff)) }
        return scored.indices
            .sortedWith { left, right ->
                val leftScore = scored[left].second
                val rightScore = scored[right].second
                if (leftScore == rightScore) compareOrder(order(scored[left].first), order(scored[right].first))
                else rightScore.compareTo(leftScore)
            }
            .take(maxOf(0, limit))
            .mapIndexed { priority, index -> Ranked(scored[index].first, priority) }
            .sortedWith { left, right -> compareOrder(order(left.retrieved), order(right.retrieved)) }
    }

    /**
     * The best [count] of them, in the order they arrived.
     *
     * **A filter, never a re-sort.** `order` is `(spineIndex, ordinal)`, and
     * that pair is not unique: [EvidenceFinder] mints several sentence windows
     * out of one paragraph, all carrying its ordinal, which is why
     * `inBookOrder` sorts on `(spineIndex, start)` instead. Re-sorting here
     * could hand the model one paragraph's sentences in the wrong order.
     *
     * Nested, too: `best(r, k)` is a subset of `best(r, k + 1)`, because the
     * index breaks every tie. The retry ladder and the builder's trimming both
     * ask for a smaller [count] each time round and rely on the answer
     * shrinking rather than shuffling.
     */
    fun best(ranked: List<Ranked>, count: Int): List<Ranked> {
        if (count >= ranked.size) return ranked
        val keep = ranked.indices
            .sortedWith(compareBy({ ranked[it].priority }, { it }))
            .take(maxOf(0, count))
            .toSet()
        return ranked.indices.filter { it in keep }.map { ranked[it] }
    }

    /**
     * The score for one passage. Public so a test can assert the arithmetic
     * rather than only its consequences.
     */
    fun score(candidate: RetrievedPassage, terms: QueryTerms, isRecent: Boolean): Double {
        // SQLite's bm25 is negative and better the lower it is; negating makes
        // "higher is better" true for the whole expression, which is the only
        // way the additive bonuses below mean anything.
        var total = -candidate.bm25

        val haystack = candidate.passage.text.lowercasedSwift()
        val distinctNames = terms.names.count { haystack.contains(it.lowercasedSwift()) }
        total += Weights.coOccurrence * maxOf(0, distinctNames - 1).toDouble()

        val groupsPresent = terms.kinshipGroups.count { group -> group.any { haystack.contains(it) } }
        total += Weights.kinship * groupsPresent.toDouble()

        if (isRecent) total += Weights.recency
        return total
    }

    // Recency

    /**
     * The position of the `recentWindow`-th passage back from the furthest
     * candidate — the cheapest usable definition of "just read" given that the
     * candidates are already bounded by the reading position.
     */
    internal fun recencyCutoff(candidates: List<RetrievedPassage>): Pair<Int, Int> {
        val positions = candidates.map { order(it) }.sortedWith(::compareOrder)
        val index = maxOf(0, positions.size - Weights.recentWindow)
        return positions[index]
    }

    internal fun isRecent(candidate: RetrievedPassage, cutoff: Pair<Int, Int>): Boolean = compareOrder(order(candidate), cutoff) >= 0

    internal fun order(retrieved: RetrievedPassage): Pair<Int, Int> = retrieved.passage.spineIndex to retrieved.passage.ordinal

    private fun compareOrder(left: Pair<Int, Int>, right: Pair<Int, Int>): Int =
        if (left.first != right.first) left.first.compareTo(right.first) else left.second.compareTo(right.second)
}
