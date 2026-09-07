import Foundation

/// Reads a name out of a sentence that states a relationship.
///
/// "What is the name of Vin's brother?" is not a question a 3B model should be
/// asked. The book contains one sentence that answers it — "Her brother, Reen,
/// had trained her…" — and once retrieval has found that sentence, the answer
/// is a pattern match, not an inference. Handing it to the model instead costs
/// several seconds and introduces the possibility of "Quellion".
///
/// So the table below is short and deliberately literal, and everything about
/// it is tuned to fail *quietly*. Over-reach is a confident wrong answer with a
/// citation on it; under-reach is the model answering with the right sentence
/// still in front of it. Only the second of those is recoverable.
public enum KinshipExtractor {
    /// One name the evidence states is the subject's relative.
    public struct Match: Sendable, Hashable {
        public var name: String
        /// Which piece of evidence said so, so the answer can cite it.
        public var evidenceIndex: Int

        public init(name: String, evidenceIndex: Int) {
            self.name = name
            self.evidenceIndex = evidenceIndex
        }
    }

    /// Every distinct name the evidence names as this relative, first mention
    /// first.
    public static func names(
        subject: Subject,
        relation: KinRelation?,
        in evidence: [Evidence],
        knownNames: Set<String> = [],
    ) -> [Match] {
        let patterns = Patterns(subject: subject)
        var found: [Match] = []
        var seen = Set<String>()
        // Kinship sentences only. A kinship question that found too little is
        // topped up with whole passages, and running a pattern table over a
        // paragraph finds every name standing near a family word — which is
        // two candidates, which declines, which throws away the answer the
        // book actually stated.
        for (index, piece) in evidence.enumerated() where piece.role == .kinship {
            for name in names(
                subject: subject, relation: relation, patterns: patterns,
                sentence: piece.sentenceText, preceding: piece.precedingText,
                knownNames: knownNames,
            ) where seen.insert(NameFinder.Name.key(for: name)).inserted {
                found.append(Match(name: name, evidenceIndex: index))
            }
        }
        return found
    }

    /// The answer, when the evidence states exactly one.
    ///
    /// Only for "who is X's brother" — a yes/no question ("Is Reen Vin's
    /// brother?") and "how are they related" both need prose, and answering
    /// either with a bare name is answering a question nobody asked. Two names
    /// is the book naming two brothers, or the pattern matching something it
    /// should not have; either way the model reads the sentences instead.
    public static func answer(
        subject: Subject,
        relation: KinRelation?,
        form: QuestionKind.KinshipForm,
        in evidence: [Evidence],
        knownNames: Set<String> = [],
    ) -> AskAnswer? {
        guard form == .whoIs, let relation else { return nil }
        let matches = names(
            subject: subject, relation: relation, in: evidence, knownNames: knownNames,
        )
        guard matches.count == 1, let match = matches.first else { return nil }
        return AskAnswer(
            text: "\(subject.display)'s \(relation.word) is \(match.name).",
            // One-based, the way the prompt numbers its excerpts.
            citations: [match.evidenceIndex + 1],
            notYetRevealed: false,
        )
    }

    // MARK: - One sentence

    static func names(
        subject: Subject,
        relation: KinRelation?,
        patterns: Patterns,
        sentence: String,
        preceding: String?,
        knownNames: Set<String>,
    ) -> [String] {
        let words = Words.split(sentence)
        guard !words.isEmpty else { return [] }
        let namesSubject = patterns.mentions(EvidenceFinder.fold(sentence))
        let kinWords = relation.map { Set($0.forms).union($0.group) } ?? Set(KinRelation.allForms)

        var found: [String] = []
        for (index, word) in words.enumerated() where kinWords.contains(word.token) {
            guard !isNegated(words, around: index) else { continue }

            // Everything in the table has either the subject's possessive or a
            // pronoun immediately before the relation, once the adjectives
            // ("her own younger brother") are stepped over.
            var owner = index - 1
            while owner >= 0, adjectives.contains(words[owner].token) { owner -= 1 }
            guard owner >= 0 else { continue }
            let ownerWord = words[owner]

            if ownerWord.isPossessive, subject.tokens.contains(ownerWord.token) {
                // "X's KIN, NAME" · "NAME, X's KIN" · "NAME was X's KIN" ·
                // "X's KIN was called NAME"
                found.append(contentsOf: candidates(
                    words, kin: index, owner: owner, subject: subject, kinWords: kinWords,
                    knownNames: knownNames,
                ))
            } else if pronouns.contains(ownerWord.token) {
                // "PRON KIN, NAME" · "NAME, PRON KIN", and only where the
                // pronoun can only be the subject: one sentence of reach,
                // because two is a guess.
                guard namesSubject
                    || onlyNames(subject, in: preceding, patterns: patterns,
                                 knownNames: knownNames)
                else { continue }
                found.append(contentsOf: candidates(
                    words, kin: index, owner: owner, subject: subject, kinWords: kinWords,
                    knownNames: knownNames,
                ))
            }
        }
        return found
    }

    /// The names sitting in the places the table allows.
    static func candidates(
        _ words: [Words.Word],
        kin: Int,
        owner: Int,
        subject: Subject,
        kinWords: Set<String>,
        knownNames: Set<String>,
    ) -> [String] {
        var found: [String] = []
        let valid = { (index: Int) -> String? in
            name(words, at: index, subject: subject, kinWords: kinWords, knownNames: knownNames)
        }

        // "…her brother, Reen, had trained her" — the appositive, which is how
        // a novel most often states a relationship.
        if words[kin].followedByComma, let name = valid(kin + 1) { found.append(name) }

        // "Reen, her brother, said nothing" — the appositive the other way up.
        if owner > 0, words[owner - 1].followedByComma {
            if let name = nameEnding(words, at: owner - 1, subject: subject,
                                     kinWords: kinWords, knownNames: knownNames) {
                found.append(name)
            }
        }

        // "Reen was her brother."
        if owner > 1, copulas.contains(words[owner - 1].token),
           let name = nameEnding(words, at: owner - 2, subject: subject,
                                 kinWords: kinWords, knownNames: knownNames) {
            found.append(name)
        }

        // "Her brother was called Reen." / "Her brother is Reen."
        if kin + 1 < words.count, copulas.contains(words[kin + 1].token) {
            var start = kin + 2
            if start < words.count, ["called", "named"].contains(words[start].token) { start += 1 }
            if let name = valid(start) { found.append(name) }
        }
        return found
    }

    // MARK: - What counts as a name

    /// A capitalised one- or two-word name beginning at `index`.
    static func name(
        _ words: [Words.Word], at index: Int, subject: Subject,
        kinWords: Set<String>, knownNames: Set<String>,
    ) -> String? {
        var start = index
        guard start >= 0, start < words.count else { return nil }
        // "Mr. Rabbit" and "Rabbit" are one person; the honorific is not part
        // of the answer.
        if NameFinder.honorifics.contains(words[start].token), start + 1 < words.count {
            start += 1
        }
        guard isName(words, at: start, subject: subject, kinWords: kinWords,
                     knownNames: knownNames) else { return nil }
        var display = words[start].display
        // A second capital that is not a new clause: "Reen Venture", not
        // "Reen, Kelsier".
        if !words[start].followedByComma, start + 1 < words.count,
           isName(words, at: start + 1, subject: subject, kinWords: kinWords,
                  knownNames: knownNames) {
            display += " " + words[start + 1].display
        }
        return display
    }

    /// The same, for a name that *ends* at `index` — the appositive read
    /// backwards.
    static func nameEnding(
        _ words: [Words.Word], at index: Int, subject: Subject,
        kinWords: Set<String>, knownNames: Set<String>,
    ) -> String? {
        guard index >= 0, index < words.count else { return nil }
        if index > 0, isName(words, at: index - 1, subject: subject, kinWords: kinWords,
                             knownNames: knownNames),
           !words[index - 1].followedByComma {
            return name(words, at: index - 1, subject: subject, kinWords: kinWords,
                        knownNames: knownNames)
        }
        return name(words, at: index, subject: subject, kinWords: kinWords,
                    knownNames: knownNames)
    }

    static func isName(
        _ words: [Words.Word], at index: Int, subject: Subject,
        kinWords: Set<String>, knownNames: Set<String>,
    ) -> Bool {
        guard index >= 0, index < words.count else { return false }
        let word = words[index]
        guard word.isCapitalised else { return false }
        guard word.display.filter(\.isLetter).count >= 2 else { return false }
        guard !subject.tokens.contains(word.token) else { return false }
        guard !kinWords.contains(word.token), !pronouns.contains(word.token) else { return false }
        guard !QueryTerms.stopWords.contains(word.token) else { return false }
        guard !QueryTerms.capitalisedNonNames.contains(word.token) else { return false }
        guard !NameFinder.honorifics.contains(word.token) else { return false }
        // Every sentence starts with a capital, so the first word is only a
        // name when the book has already used it as one.
        if index == 0 { return knownNames.contains(word.token) }
        return true
    }

    /// Whether the preceding sentence names the subject and nobody else.
    ///
    /// One sentence of reach and no ambiguity in it. "Vin turned away. Kelsier
    /// watched. Her brother, Reen, …" must not answer, because "her" is as
    /// likely to be somebody else's.
    static func onlyNames(
        _ subject: Subject, in preceding: String?, patterns: Patterns, knownNames: Set<String>,
    ) -> Bool {
        guard let preceding else { return false }
        guard patterns.mentions(EvidenceFinder.fold(preceding)) else { return false }
        // A competing *person*, not a competing capital. "Vin had grown up on
        // the streets of Luthadel" has one person in it and one place, and a
        // rule that counted capitals would decline every sentence that
        // mentioned where it happened — which is most of them.
        for found in NameFinder.names(in: preceding, spineIndex: 0) {
            let tokens = QueryTerms.tokens(in: found.name).map(QueryTerms.strippingPossessive)
            guard !tokens.allSatisfy({ subject.tokens.contains($0) }) else { continue }
            return false
        }
        // …and the book's own table besides, because the tagger tags none of
        // the invented names, which are the ones readers ask about.
        for word in Words.split(preceding)
            where word.isCapitalised && !subject.tokens.contains(word.token) {
            if knownNames.contains(word.token) { return false }
        }
        return true
    }

    /// A negation anywhere near the relation, which reverses what the sentence
    /// says without changing a single one of the words the table matches on.
    static func isNegated(_ words: [Words.Word], around index: Int) -> Bool {
        let lower = max(0, index - negationReach)
        let upper = min(words.count - 1, index + negationReach)
        return words[lower ... upper].contains { negations.contains($0.token) }
    }

    static let negationReach = 4
    static let negations: Set<String> = [
        "not", "no", "never", "nor", "neither", "n't", "isn't", "wasn't", "weren't",
        "hadn't", "hasn't", "didn't", "doesn't", "don't", "without", "unlike", "except",
    ]
    static let pronouns: Set<String> = ["his", "her", "their", "its", "my", "your", "our"]
    static let copulas: Set<String> = ["was", "is", "were", "are", "became"]
    /// Adjectives a book puts between the owner and the relation.
    static let adjectives: Set<String> = [
        "own", "elder", "older", "younger", "little", "big", "twin", "half",
        "only", "dear", "beloved", "poor", "eldest", "youngest", "step", "late",
        "adopted", "foster", "youngest", "oldest",
    ]
}
