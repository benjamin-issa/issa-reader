import Foundation
import NaturalLanguage

/// What a reader's question is actually asking the index for.
///
/// Retrieval is the whole feature: a 4,096-token window cannot hold the book,
/// so the six passages this picks are the entire evidence the model gets. Three
/// things had to be handled for ordinary questions to work at all.
///
/// 1. **Names**, because "Who is the Cheshire Cat?" is a name lookup and a
///    plain token match ranks every paragraph containing "cat".
/// 2. **Kinship**, because a novel almost never repeats the word in the
///    question: a reader asks about a *cousin* and the text says *nephew*,
///    *aunt*, *family*. Expanding the group is the difference between six
///    relevant passages and none.
/// 3. **Recap**, because "what has happened so far" has no search terms in it
///    at all and must take the last passages before the boundary instead.
public struct QueryTerms: Sendable, Hashable {
    /// The question after sanitising — what the model is shown, verbatim.
    public var question: String
    /// Personal names the question mentions, either tagged by `NLTagger` or
    /// promoted because the book's own name table knows them.
    public var names: [String]
    /// Content words, stop list removed, names included.
    public var terms: [String]
    /// Terms added by kinship expansion, kept apart so the ranker can reward a
    /// passage for containing a *group*, not merely more words.
    public var kinshipGroups: [[String]]
    /// Every word in the question that looks like something the book would have
    /// had to introduce: a tagged name, a name the index recognised, or a
    /// capitalised word that is not merely starting the sentence.
    ///
    /// This is the input to the spoiler short-circuit, and it exists because of
    /// a real answer the on-device model gave during development: asked "Who is
    /// the Cheshire Cat?" from the end of Chapter I, it was handed six excerpts
    /// containing no cat but Dinah, and answered "The Cheshire Cat is a talking
    /// cat known for his mischievous behaviour" — from memory, ten chapters
    /// ahead of the reader, in flat defiance of instructions that told it twice
    /// not to. The model cannot be relied on to refuse; the app has to.
    public var nameCandidates: [String]
    /// What shape of question this is, which decides which retrieval runs.
    public var kind: QuestionKind

    /// "What has happened so far?" and its relatives, which take the passages
    /// before the boundary rather than a search.
    ///
    /// Derived rather than stored, so there is one answer to "is this a recap"
    /// and the retriever's `switch` cannot disagree with it.
    public var isRecap: Bool { kind.isRecap }

    /// Whoever the question is about, when it is about anybody. Every retrieval
    /// path except the recap requires this of a passage before considering it.
    public var subject: Subject? { kind.subject }

    public init(
        question: String,
        names: [String],
        terms: [String],
        kinshipGroups: [[String]],
        nameCandidates: [String] = [],
        kind: QuestionKind,
    ) {
        self.question = question
        self.names = names
        self.terms = terms
        self.kinshipGroups = kinshipGroups
        self.nameCandidates = nameCandidates
        self.kind = kind
    }

    /// Longest first, so the FTS pattern leads with the most selective token.
    public var searchTokens: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for token in terms + kinshipGroups.flatMap({ $0 }) where seen.insert(token).inserted {
            ordered.append(token)
        }
        return ordered
    }

    // MARK: - Building

    /// The longest question that is worth anything. Past this it is a pasted
    /// paragraph, not a question, and every token in it dilutes the match.
    public static let maximumQuestionLength = 300

    /// - Parameter knownNames: the book's own name table, bounded by the
    ///   reading position. A token matching one is promoted to a name even when
    ///   `NLTagger` did not tag it — invented names ("Cheshire", "Bilbo") are
    ///   exactly the ones a general-purpose tagger misses, and exactly the ones
    ///   readers ask about.
    public static func extract(from question: String, knownNames: [String] = []) -> QueryTerms {
        let sanitised = sanitise(question)
        let known = Set(knownNames.map { $0.lowercased() })

        var names = taggedNames(in: sanitised)
        var terms: [String] = []
        for raw in tokens(in: sanitised) {
            // The possessive is stripped *here* rather than inside `tokens`,
            // which the FTS pattern tests depend on. "Vin's" has to become the
            // name `vin`: left alone it is neither a known name nor a term the
            // co-occurrence bonus can see, and SQLite's tokeniser reads it as
            // `vin OR s` — which is how "What is the name of Vin's brother?"
            // came back with a pool that never contained "Her brother, Reen".
            let token = strippingPossessive(raw)
            if known.contains(token) || known.contains(where: { $0.hasPrefix(token + " ") }) {
                if !names.contains(where: { $0.lowercased() == token }) { names.append(token) }
                terms.append(token)
                continue
            }
            guard !stopWords.contains(token), token.count > 1 else { continue }
            terms.append(token)
        }
        // A tagged multi-word name contributes its parts as search tokens; FTS5
        // indexes words, not phrases.
        for name in names {
            for part in tokens(in: name).map(strippingPossessive)
                where !terms.contains(part) && part.count > 1 {
                terms.append(part)
            }
        }

        return QueryTerms(
            question: sanitised,
            names: names,
            terms: terms,
            kinshipGroups: Kinship.groups(matching: terms),
            nameCandidates: nameCandidates(in: sanitised, names: names),
            // Classified from the names already found, rather than running
            // `NLTagger` a second time: one pass over a question is a
            // millisecond, and two is two.
            kind: QuestionReader.kind(of: sanitised, vocabulary: Vocabulary(
                known: known,
                tagged: Set(names.flatMap { tokens(in: $0).map(strippingPossessive) }),
            )),
        )
    }

    /// "Vin's" → "Vin", "James'" → "James", everything else untouched.
    ///
    /// Applied to tokens rather than inside `tokens(in:)` on purpose: that
    /// function's output is what the FTS pattern is built from in the older
    /// call sites and in the tests, and changing it would move offsets nobody
    /// asked to move.
    public static func strippingPossessive(_ token: String) -> String {
        guard token.count > 2, token.hasSuffix("'s") else { return token }
        return String(token.dropLast(2))
    }

    /// Words the book would have had to introduce for the question to be
    /// answerable at all.
    ///
    /// Capitalisation rather than `NLTagger` alone, because the names readers
    /// ask about are the invented ones — "Cheshire", "Bilbo", "Meursault" — and
    /// a general-purpose tagger knows none of them. The first word of the
    /// question is skipped: every question starts with a capital.
    ///
    /// Some ordinary words will be caught by this ("Is Alice British?"), and
    /// the cost of that is a "the story hasn't revealed that yet" for a question
    /// the model might have answered. That is the right way round: a wrong
    /// refusal is an annoyance the reader can rephrase past, and a wrong answer
    /// about a character forty pages ahead is the thing this feature promised
    /// not to do.
    public static func nameCandidates(in question: String, names: [String]) -> [String] {
        var candidates = Set(names.flatMap { tokens(in: $0).map(strippingPossessive) })
        for (index, word) in question.split(separator: " ").enumerated() where index > 0 {
            let bare = word.trimmingCharacters(in: CharacterSet.letters.inverted)
            guard let initial = bare.first, initial.isUppercase, bare.count > 2 else { continue }
            guard !capitalisedNonNames.contains(bare.lowercased()) else { continue }
            // Possessive-stripped, or "Vin's" is checked against the index as
            // `vin's` — a word no book contains as one token, so the spoiler
            // guard tests something that is not the name.
            candidates.formUnion(tokens(in: bare).map(strippingPossessive))
        }
        return candidates.filter { $0.count > 2 }.sorted()
    }

    /// Words a sentence capitalises for grammar rather than for a person.
    ///
    /// The contrast with `capitalisedNonNames` below is the whole design. That
    /// list is exempt *everywhere* in an answer, so every word on it is a word
    /// the book can never be caught spoiling, and it stays short. This one is
    /// exempt only where a sentence had to capitalise the word anyway — the
    /// first position — so it can afford to be long: a word here is still
    /// checked in every other position it appears in.
    ///
    /// Closed-class only. Determiners, pronouns, auxiliaries, connectives and
    /// the adverbs that open sentences; nothing that names or describes. That
    /// is the test for admitting a word, and it is why these are **deliberately
    /// absent**: `will`, `may`, `mark`, `grace`, `rose`, `hope`, `faith`,
    /// `bill`, `frank`, `jack`, `art`, `dawn`, `june`, `pat`, `sue`, `victor`.
    /// Every one is a name somebody has, and membership is an exemption for
    /// ever — the cost of leaving them off is one wrong refusal that the reader
    /// can rephrase past. (`march` and `june` are exempt everywhere through
    /// `capitalisedNonNames`, which is a judgement made there, not here.)
    ///
    /// A word not on this list that opens a sentence is a candidate, and
    /// `AskIndexStore.unmetWords` then decides it per book: over-catching only
    /// costs anything when the over-caught word is absent from the part the
    /// reader has read. "Rome" is in *Alice* Chapter II — "London is the capital
    /// of Paris, and Paris is the capital of Rome" — so it is cleared from
    /// there onwards and refused before it, which is exactly right.
    static let sentenceOpeners: Set<String> = [
        // Determiners and quantifiers.
        "a", "an", "the", "this", "that", "these", "those", "each", "every",
        "some", "any", "no", "all", "both", "either", "neither", "another",
        "such", "much", "many", "few", "fewer", "several", "most", "more",
        "less", "least", "enough", "other", "half",
        // Pronouns.
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "us", "them",
        "my", "your", "his", "her", "its", "our", "their", "mine", "yours",
        "hers", "ours", "theirs", "myself", "yourself", "himself", "herself",
        "itself", "ourselves", "themselves", "who", "whom", "whose", "which",
        "what", "whatever", "whoever", "whichever", "someone", "somebody",
        "something", "anyone", "anybody", "anything", "everyone", "everybody",
        "everything", "nobody", "nothing", "none", "one", "ones",
        // Auxiliaries and copulas.
        "am", "is", "are", "was", "were", "being", "been", "be", "do", "does",
        "did", "doing", "done", "have", "has", "had", "having", "can", "could",
        "shall", "should", "would", "must", "might", "ought", "cannot",
        // Connectives.
        "and", "but", "or", "nor", "for", "yet", "so", "because", "since",
        "although", "though", "while", "whilst", "whereas", "unless", "until",
        "till", "if", "then", "than", "as", "when", "whenever", "where",
        "wherever", "after", "before", "once", "whether", "however",
        "therefore", "thus", "hence", "moreover", "furthermore",
        "nevertheless", "nonetheless", "besides", "meanwhile", "otherwise",
        "instead", "also",
        // Prepositions and particles that open a clause.
        "at", "by", "in", "on", "to", "of", "with", "without", "within",
        "from", "into", "onto", "upon", "over", "under", "above", "below",
        "through", "across", "along", "around", "behind", "beyond", "during",
        "against", "between", "among", "beside", "toward", "towards", "off",
        "out", "up", "down", "back", "away",
        // Adverbs that open sentences.
        "not", "never", "always", "often", "sometimes", "soon", "now", "later",
        "again", "already", "almost", "nearly", "just", "only", "even",
        "quite", "rather", "very", "really", "perhaps", "maybe", "probably",
        "possibly", "certainly", "surely", "indeed", "actually", "finally",
        "eventually", "suddenly", "immediately", "still", "here", "there",
        "everywhere", "somewhere", "anywhere", "nowhere", "together", "yes",
        "well", "why", "how", "let", "there's", "it's", "that's", "here's",
    ]

    /// Words that are capitalised in ordinary prose without naming anybody.
    /// Short on purpose: a long list here is a long list of things a book can
    /// spoil.
    static let capitalisedNonNames: Set<String> = [
        "chapter", "section", "part", "book", "volume", "page",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Collapses whitespace and clamps the length. Nothing is escaped here —
    /// the FTS pattern is built by `FTS5Pattern`, which is the only thing that
    /// can be trusted to quote for SQLite's tokeniser.
    public static func sanitise(_ question: String) -> String {
        let collapsed = question
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumQuestionLength else { return collapsed }
        return String(collapsed.prefix(maximumQuestionLength))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lowercased word tokens, apostrophes and hyphens kept inside a word.
    ///
    /// A curly apostrophe is folded to a straight one, because the book's text
    /// carries whichever its typesetter used and the two must tokenise the same
    /// — this is the difference between "Alice's" matching and matching nothing.
    public static func tokens(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let folded = text.folding(
            options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"),
        )
        for character in folded {
            if character.isLetter || character.isNumber {
                // The lowercase of one character is not always one character
                // ("İ" is two), so append the string rather than forcing it
                // back into a `Character` and trapping on a German or Turkish
                // question.
                current.append(contentsOf: character.lowercased())
            } else if character == "'" || character == "\u{2019}" || character == "-" {
                // Kept only *inside* a word, so a leading quotation mark does
                // not open a token that FTS5 then reads as a phrase.
                if !current.isEmpty { current.append("'") }
            } else if !current.isEmpty {
                out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
                current = ""
            }
        }
        if !current.isEmpty {
            out.append(current.trimmingCharacters(in: CharacterSet(charactersIn: "'")))
        }
        return out.filter { !$0.isEmpty }
    }

    static func taggedNames(in text: String) -> [String] {
        NameFinder.names(in: text, spineIndex: 0).map(\.name)
    }

    /// Questions that are asking for the story so far rather than for a fact.
    static func isRecapQuestion(_ question: String) -> Bool {
        let lowered = question.lowercased()
        return recapPatterns.contains { lowered.contains($0) }
    }

    static let recapPatterns: [String] = [
        "what has happened", "what's happened", "what happened so far",
        "recap", "summarise", "summarize", "summary",
        "catch me up", "remind me what", "where was i", "where am i",
        "what have i read", "so far in the story", "what's the story so far",
        "story so far",
    ]

    /// Words that carry no retrieval signal. Deliberately short: an aggressive
    /// stop list throws away "who", which is the one word that says the answer
    /// is a person, and the ranker wants that signal.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "than", "that",
        "this", "these", "those", "is", "are", "was", "were", "be", "been",
        "being", "am", "do", "does", "did", "doing", "have", "has", "had",
        "having", "of", "in", "on", "at", "to", "for", "with", "from", "by",
        "about", "into", "over", "after", "before", "up", "down", "out",
        "it", "its", "he", "she", "they", "them", "his", "her", "their",
        "i", "me", "my", "we", "us", "our", "you", "your",
        "what", "when", "where", "why", "how", "which", "there", "here",
        "so", "far", "just", "very", "can", "could", "would", "should",
        "will", "shall", "may", "might", "must", "not", "no", "yes",
        "please", "tell", "again", "any", "some", "all",
    ]
}

// MARK: -

/// Family words, grouped so a question about one reaches passages about the
/// others.
///
/// The point is recall, not synonymy: nobody claims a cousin is an aunt. A
/// novel introduces a relative once and then refers to them by name, so the
/// only paragraphs that will ever contain "cousin" are the two that introduce
/// them — and a question asked forty pages later matches neither without this.
public enum Kinship {
    /// One group per relationship a reader asks about. A term in any group
    /// pulls in the whole group.
    ///
    /// **The only place a family word is written down.** `KinRelation.all`
    /// reads its relations out of these groups rather than keeping a second
    /// list, because there were two lists and they disagreed in both
    /// directions. This one had "relative", "family", "grandparent" and
    /// "companion" and `KinRelation` had none of them, so "Who is X's
    /// relative?" never reached the kinship path at all and was answered by
    /// BM25 over the whole question; `KinRelation` had "grandmothers",
    /// "widows" and "wives" and this one had none of them, so a question using
    /// one of those expanded to nothing.
    public static let all: [[String]] = [
        ["cousin", "cousins", "relative", "relatives", "relation", "relations",
         "family", "families", "kin"],
        ["brother", "brothers", "sister", "sisters", "sibling", "siblings"],
        ["mother", "mothers", "mum", "mama", "mamma",
         "father", "fathers", "papa", "dad", "parent", "parents"],
        ["aunt", "aunts", "uncle", "uncles", "niece", "nieces", "nephew", "nephews"],
        ["husband", "husbands", "wife", "wives", "spouse", "spouses",
         "widow", "widows", "widower", "widowers", "married", "marriage"],
        ["son", "sons", "daughter", "daughters", "child", "children", "baby", "babies"],
        ["grandmother", "grandmothers", "grandma", "grandfather", "grandfathers", "grandpa",
         "grandparent", "grandparents", "grandson", "grandsons",
         "granddaughter", "granddaughters", "grandchild", "grandchildren"],
        ["friend", "friends", "friendship", "companion", "companions"],
    ]

    /// Every group at least one of these terms belongs to.
    public static func groups(matching terms: [String]) -> [[String]] {
        let lowered = Set(terms.map { $0.lowercased() })
        return all.filter { group in group.contains { lowered.contains($0) } }
    }
}
