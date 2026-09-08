import Foundation

/// Chooses which six passages the model actually sees.
///
/// BM25 alone is not enough, and the reason is specific to fiction. A question
/// like "How is Alice related to her sister?" is answered by the paragraph
/// where both appear together, and BM25 will happily rank six paragraphs that
/// mention Alice forty times each above the one paragraph that mentions both
/// once. So co-occurrence of *distinct* names is rewarded outright, and a
/// passage containing a whole kinship group is rewarded again — those are the
/// two signals that separate "about this" from "contains this word".
///
/// The recency bonus is small and deliberate: a reader almost always asks about
/// what they have just read, but "almost always" is not "always", and a large
/// bonus would bury the one early paragraph that introduced a character.
public enum PassageRanker {
    /// The weights, in one place so a test asserts against the shipped numbers.
    public enum Weights {
        /// Per distinct question-name beyond the first that a passage contains.
        public static let coOccurrence = 2.5
        /// Per kinship group the passage has a member of.
        public static let kinship = 0.6
        /// Flat bonus for being among the last passages before the boundary.
        public static let recency = 0.5
        /// How many passages count as "recent".
        public static let recentWindow = 8
    }

    /// A passage and how badly the question wants it, for the trimming and the
    /// retry ladder to sacrifice the right ones.
    ///
    /// An ordinal rather than a score, and zero is best. Two finders' numbers
    /// meet in one array at the kinship top-up, and a BM25-derived score there
    /// would let a book's term statistics decide that a context paragraph
    /// outranks the kinship sentence it was context for.
    public struct Ranked: Sendable, Hashable {
        public var retrieved: RetrievedPassage
        /// Position among the passages this question retrieved. Required at
        /// every call site on purpose: this replaced a `score` that was
        /// identically zero on every production path, and a path that forgets
        /// to stamp it should fail to compile rather than quietly revert to
        /// book order.
        public var priority: Int

        public init(retrieved: RetrievedPassage, priority: Int) {
            self.retrieved = retrieved
            self.priority = priority
        }

        public var passage: Passage { retrieved.passage }
    }

    /// Scores, takes the best `limit`, and puts them back into book order —
    /// keeping the permutation it computed on the way.
    ///
    /// Book order matters to the answer, not to the retrieval: the model is
    /// told the excerpts are in reading order, and a model handed events out of
    /// sequence invents a chronology to explain them. But the second sort used
    /// to throw the first one away, and everything downstream — the trimming,
    /// the retry ladder — then had nothing to go on but position. So the place
    /// a passage came in the score sort is written down as its `priority`.
    public static func rank(
        _ candidates: [RetrievedPassage], terms: QueryTerms, limit: Int = 6,
    ) -> [Ranked] {
        guard !candidates.isEmpty else { return [] }
        let recentCutoff = recencyCutoff(candidates)

        let scored = candidates.map { candidate in
            (candidate, score(
                candidate, terms: terms, isRecent: isRecent(candidate, after: recentCutoff),
            ))
        }
        return scored.indices
            .sorted {
                scored[$0].1 == scored[$1].1
                    ? order(scored[$0].0) < order(scored[$1].0)
                    : scored[$0].1 > scored[$1].1
            }
            .prefix(limit)
            .enumerated()
            .map { Ranked(retrieved: scored[$0.element].0, priority: $0.offset) }
            .sorted { order($0.retrieved) < order($1.retrieved) }
    }

    /// The best `count` of them, in the order they arrived.
    ///
    /// **A filter, never a re-sort.** `order` is `(spineIndex, ordinal)`, and
    /// that pair is not unique: `EvidenceFinder` mints several sentence windows
    /// out of one paragraph, all carrying its ordinal, which is why
    /// `inBookOrder` sorts on `(spineIndex, start)` instead. `Array.sorted` is
    /// not stable, so sorting here could hand the model one paragraph's
    /// sentences in the wrong order — and no test in the suite would notice.
    ///
    /// Nested, too: `best(r, k)` is a subset of `best(r, k + 1)`, because the
    /// index breaks every tie. The retry ladder and the builder's trimming both
    /// ask for a smaller `count` each time round and rely on the answer
    /// shrinking rather than shuffling.
    public static func best(_ ranked: [Ranked], count: Int) -> [Ranked] {
        guard count < ranked.count else { return ranked }
        let keep = Set(
            ranked.indices
                .sorted { (ranked[$0].priority, $0) < (ranked[$1].priority, $1) }
                .prefix(max(0, count)),
        )
        return ranked.indices.filter(keep.contains).map { ranked[$0] }
    }

    /// The score for one passage. Public so a test can assert the arithmetic
    /// rather than only its consequences.
    public static func score(
        _ candidate: RetrievedPassage, terms: QueryTerms, isRecent: Bool,
    ) -> Double {
        // SQLite's bm25 is negative and better the lower it is; negating makes
        // "higher is better" true for the whole expression, which is the only
        // way the additive bonuses below mean anything.
        var total = -candidate.bm25

        let haystack = candidate.passage.text.lowercased()
        let distinctNames = terms.names.reduce(into: 0) { count, name in
            if haystack.contains(name.lowercased()) { count += 1 }
        }
        total += Weights.coOccurrence * Double(max(0, distinctNames - 1))

        let groupsPresent = terms.kinshipGroups.reduce(into: 0) { count, group in
            if group.contains(where: { haystack.contains($0) }) { count += 1 }
        }
        total += Weights.kinship * Double(groupsPresent)

        if isRecent { total += Weights.recency }
        return total
    }

    // MARK: - Recency

    /// The position of the `recentWindow`-th passage back from the furthest
    /// candidate — the cheapest usable definition of "just read" given that the
    /// candidates are already bounded by the reading position.
    static func recencyCutoff(_ candidates: [RetrievedPassage]) -> (Int, Int) {
        let positions = candidates
            .map { ($0.passage.spineIndex, $0.passage.ordinal) }
            .sorted { $0 < $1 }
        let index = max(0, positions.count - Weights.recentWindow)
        return positions[index]
    }

    static func isRecent(_ candidate: RetrievedPassage, after cutoff: (Int, Int)) -> Bool {
        (candidate.passage.spineIndex, candidate.passage.ordinal) >= cutoff
    }

    static func order(_ retrieved: RetrievedPassage) -> (Int, Int) {
        (retrieved.passage.spineIndex, retrieved.passage.ordinal)
    }
}
