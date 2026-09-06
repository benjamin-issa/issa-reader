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

    /// A passage with its score, for tests and for the prompt builder's
    /// "drop the lowest-ranked" trimming.
    public struct Ranked: Sendable, Hashable {
        public var retrieved: RetrievedPassage
        public var score: Double

        public init(retrieved: RetrievedPassage, score: Double) {
            self.retrieved = retrieved
            self.score = score
        }

        public var passage: Passage { retrieved.passage }
    }

    /// Scores, takes the best `limit`, and puts them back into book order.
    ///
    /// Book order matters to the answer, not to the retrieval: the model is
    /// told the excerpts are in reading order, and a model handed events out of
    /// sequence invents a chronology to explain them.
    public static func rank(
        _ candidates: [RetrievedPassage], terms: QueryTerms, limit: Int = 6,
    ) -> [Ranked] {
        guard !candidates.isEmpty else { return [] }
        let recentCutoff = recencyCutoff(candidates)

        let scored = candidates.map { candidate -> Ranked in
            Ranked(retrieved: candidate, score: score(
                candidate, terms: terms, isRecent: isRecent(candidate, after: recentCutoff),
            ))
        }
        return scored
            .sorted { $0.score == $1.score ? order($0) < order($1) : $0.score > $1.score }
            .prefix(limit)
            .sorted { order($0) < order($1) }
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

    static func order(_ ranked: Ranked) -> (Int, Int) {
        (ranked.passage.spineIndex, ranked.passage.ordinal)
    }
}
