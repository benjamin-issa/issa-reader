import Foundation

/// Who or what a question is *about*, in the form retrieval can use.
///
/// The tokens are what the FTS pattern is built from, so they are folded and
/// stripped of the possessive: the reader who types "Vin's" is asking about
/// `vin`, and a pattern built from `vin's` reaches nothing — SQLite's tokeniser
/// reads the apostrophe as a word break, which is the bug that made
/// "What is the name of Vin's brother?" search for `vin OR s`.
public struct Subject: Sendable, Hashable {
    /// The subject as the reader wrote it, articles removed: "White Rabbit",
    /// "Vin", "the Duchess" → "Duchess". Shown nowhere; used to compose the
    /// deterministic kinship answer, which has to spell the name their way.
    public var display: String
    /// Folded, lowercased, possessive-stripped. Every one of these is required
    /// of a passage before it is even considered.
    public var tokens: [String]
    /// Whether the book's own name table recognises this, which is the only
    /// reliable signal for an invented name: `NLTagger` tags neither "VIN" nor
    /// "White Rabbit" nor "Duchess" as a person.
    public var isKnownName: Bool

    public init(display: String, tokens: [String], isKnownName: Bool) {
        self.display = display
        self.tokens = tokens
        self.isKnownName = isKnownName
    }

    /// The last token, which is the head of a multi-word name ("Rabbit" of
    /// "White Rabbit") and therefore what the book usually calls it after the
    /// introduction.
    public var head: String { tokens.last ?? "" }
}

// MARK: -

/// One family word a reader can ask about, with the spellings a book might use
/// and the group that reaches its neighbours.
///
/// The group is recall, not synonymy: a novel introduces a brother once and
/// then uses his name, so a question asked forty pages later matches the
/// introduction only by way of "sibling", "sister", "brothers".
public struct KinRelation: Sendable, Hashable {
    /// The canonical singular, which is what the deterministic answer says.
    public var word: String
    /// Every spelling of this one relation.
    public var forms: [String]
    /// The whole `Kinship` group it belongs to.
    public var group: [String]

    public init(word: String, forms: [String], group: [String]) {
        self.word = word
        self.forms = forms
        self.group = group
    }

    /// The relations a question can name, longest form first so "grandmother"
    /// is never read as "mother".
    public static let all: [KinRelation] = {
        let table: [(String, [String])] = [
            ("grandmother", ["grandmother", "grandmothers", "grandma"]),
            ("grandfather", ["grandfather", "grandfathers", "grandpa"]),
            ("granddaughter", ["granddaughter", "granddaughters"]),
            ("grandson", ["grandson", "grandsons"]),
            ("grandchild", ["grandchild", "grandchildren"]),
            ("brother", ["brother", "brothers"]),
            ("sister", ["sister", "sisters"]),
            ("sibling", ["sibling", "siblings"]),
            ("mother", ["mother", "mothers", "mum", "mama", "mamma"]),
            ("father", ["father", "fathers", "papa", "dad"]),
            ("parent", ["parent", "parents"]),
            ("son", ["son", "sons"]),
            ("daughter", ["daughter", "daughters"]),
            ("child", ["child", "children"]),
            ("husband", ["husband", "husbands"]),
            ("wife", ["wife", "wives"]),
            ("spouse", ["spouse", "spouses"]),
            ("widow", ["widow", "widows", "widower"]),
            ("aunt", ["aunt", "aunts"]),
            ("uncle", ["uncle", "uncles"]),
            ("niece", ["niece", "nieces"]),
            ("nephew", ["nephew", "nephews"]),
            ("cousin", ["cousin", "cousins"]),
            ("friend", ["friend", "friends"]),
        ]
        return table.map { word, forms in
            KinRelation(
                word: word,
                forms: forms,
                group: Kinship.groups(matching: [word]).first ?? forms,
            )
        }
    }()

    /// Every spelling of every relation, for the query that has to reach a
    /// passage using a word the question never said.
    public static let allForms: [String] = {
        var seen = Set<String>()
        var ordered: [String] = []
        for relation in all {
            for form in relation.forms where seen.insert(form).inserted { ordered.append(form) }
        }
        return ordered
    }()

    static func matching(_ token: String) -> KinRelation? {
        all.first { $0.forms.contains(token) }
    }
}

// MARK: -

/// What the reader actually asked, and therefore how the book is searched.
///
/// Classification exists because BM25 over an OR of every question word answers
/// a different question from the one asked. Measured on *The Hero of Ages* at
/// the Epilogue: "What is the name of Vin's brother?" ranked the sentence that
/// says "Her brother, Reen, had trained her…" fiftieth in a pool capped at
/// forty, and the model — handed six passages, five of which never said "Vin" —
/// answered "Quellion". Knowing the question is a kinship question is what lets
/// retrieval require the subject and then look at sentences instead of
/// paragraphs.
public enum QuestionKind: Sendable, Hashable {
    /// "What has happened so far?" — no search terms at all; the passages
    /// before the boundary are the answer.
    case recap
    /// "Who is X?", "What is the X?", "Tell me about X".
    case identity(Subject)
    /// "X's brother", "the brother of X", "how are X and Y related",
    /// "is Y X's brother".
    case kinship(subject: Subject, relation: KinRelation?, other: Subject?, form: KinshipForm)
    /// Everything else. The subject, when there is one, is still required of
    /// every passage: "What is Alice's cat called?" is not about cats.
    case general(Subject?)

    /// What an answer to a kinship question would have to look like, which
    /// decides whether the deterministic extractor may answer at all.
    public enum KinshipForm: Sendable, Hashable {
        /// "Who is X's brother?" — a name is the answer, so one unambiguous
        /// name in the evidence can be answered without the model.
        case whoIs
        /// "Is Y X's brother?" — the answer is yes or no, which needs reading.
        case yesNo
        /// "How are X and Y related?" — needs prose.
        case howRelated
    }

    /// The subject every branch except `.recap` may or may not have.
    public var subject: Subject? {
        switch self {
        case .recap: nil
        case let .identity(subject): subject
        case let .kinship(subject, _, _, _): subject
        case let .general(subject): subject
        }
    }

    public var isRecap: Bool { self == .recap }

    /// For logs and for the diagnostic run, which has to say which path a
    /// question took without printing the question.
    public var label: String {
        switch self {
        case .recap: "recap"
        case .identity: "identity"
        case .kinship: "kinship"
        case .general: "general"
        }
    }
}

// MARK: - Reading the question

/// One word of the question, kept in both the reader's spelling and the
/// index's.
///
/// Both are needed: the possessive is a *display* fact ("Vin's" has an
/// apostrophe) while the search is a *token* fact (`vin`), and the classifier
/// has to see the apostrophe to know who owns the brother.
struct QuestionWord: Sendable, Hashable {
    /// As written, edge punctuation removed: "Vin's".
    var display: String
    /// The display spelling without the possessive: "Vin".
    var bare: String
    /// Folded, lowercased, possessive-stripped: "vin".
    var token: String
    var isPossessive: Bool
    var isCapitalised: Bool
}

/// What this book calls people, as far as the reader has got.
///
/// Two lists rather than one, because they fail in opposite directions.
/// `NLTagger` finds ordinary names and misses every invented one — it tags
/// neither "VIN" nor "Duchess" nor "White Rabbit" — while the book's own table
/// knows exactly the invented ones and nothing about a name the reader has not
/// reached yet. A subject has to be allowed to come from either.
struct Vocabulary: Sendable {
    /// Folded name tokens the index has seen before the boundary, including
    /// the multi-word spellings ("white rabbit").
    var known: Set<String> = []
    /// Folded tokens `NLTagger` tagged as people in this question, plus the
    /// ones the known list promoted.
    var tagged: Set<String> = []

    func isName(_ token: String) -> Bool {
        tagged.contains(token) || known.contains(token)
            || known.contains { $0.hasPrefix(token + " ") || $0.hasSuffix(" " + token) }
    }

    /// Whether the book itself knows this spelling — the signal that survives
    /// an invented name.
    func isKnownName(_ phrase: String, tokens: [String]) -> Bool {
        if known.contains(phrase) { return true }
        if tokens.contains(where: { known.contains($0) }) { return true }
        return known.contains { $0.hasPrefix(phrase + " ") || $0.hasSuffix(" " + phrase) }
    }
}

// MARK: -

enum QuestionReader {
    /// Contractions that hide an identity lead-in. "Who's Vin?" is "Who is
    /// Vin?", and reading it as one word loses the whole question shape.
    static let expansions: [String: [String]] = [
        "who's": ["who", "is"], "what's": ["what", "is"],
        "whos": ["who", "is"], "whats": ["what", "is"],
    ]

    /// Splits the sanitised question into words the classifier can reason
    /// about.
    static func words(in question: String) -> [QuestionWord] {
        var out: [QuestionWord] = []
        for chunk in question.split(whereSeparator: \.isWhitespace) {
            let display = String(chunk).trimmingCharacters(in: Self.edgePunctuation)
            guard !display.isEmpty else { continue }
            if let expanded = expansions[display.lowercased()] {
                for part in expanded {
                    out.append(QuestionWord(
                        display: part, bare: part, token: part,
                        isPossessive: false, isCapitalised: false,
                    ))
                }
                continue
            }
            let possessive = Self.possessiveSuffixes.contains { display.hasSuffix($0) }
            var bare = display
            if possessive {
                // "Vin's" loses two characters, "James'" loses one — and both
                // have to end up as the name the book actually prints.
                bare = display.hasSuffix("'s") || display.hasSuffix("\u{2019}s")
                    ? String(display.dropLast(2))
                    : String(display.dropLast())
            }
            let token = QueryTerms.strippingPossessive(QueryTerms.tokens(in: bare).joined())
            guard !token.isEmpty, !bare.isEmpty else { continue }
            out.append(QuestionWord(
                display: bare,
                bare: bare,
                token: token,
                isPossessive: possessive,
                isCapitalised: display.first?.isUppercase ?? false,
            ))
        }
        return out
    }

    /// Trailing apostrophes are kept: they are what says "Vins'" is possessive.
    static let edgePunctuation = CharacterSet(charactersIn: ".,;:!?\"“”()[]{}—–-…")
    static let possessiveSuffixes = ["'s", "\u{2019}s", "s'", "s\u{2019}"]

    // MARK: - Classifying

    /// The question's shape.
    ///
    /// Order matters. Recap first, because it has no subject at all; kinship
    /// before identity, because "Who is Alice's sister?" is both a "who is"
    /// question and a kinship one and only the kinship reading finds the
    /// sentence that answers it.
    static func kind(of question: String, vocabulary: Vocabulary) -> QuestionKind {
        guard !QueryTerms.isRecapQuestion(question) else { return .recap }
        let words = Self.words(in: question)
        guard !words.isEmpty else { return .general(nil) }

        if let kinship = kinship(in: words, vocabulary: vocabulary) { return kinship }
        if let identity = identity(in: words, vocabulary: vocabulary) { return identity }
        return .general(generalSubject(in: words, vocabulary: vocabulary))
    }

    // MARK: Kinship

    /// Adjectives a reader puts between the owner and the relation. Without
    /// these "Vin's younger brother" loses its owner and becomes a general
    /// question about brothers.
    static let kinshipAdjectives: Set<String> = [
        "own", "elder", "older", "younger", "little", "big", "twin", "half",
        "only", "dear", "beloved", "poor", "eldest", "youngest", "step",
    ]

    static func kinship(in words: [QuestionWord], vocabulary: Vocabulary) -> QuestionKind? {
        guard let kinIndex = words.firstIndex(where: { KinRelation.matching($0.token) != nil })
        else { return howRelated(in: words, vocabulary: vocabulary) }
        let relation = KinRelation.matching(words[kinIndex].token)

        // "Vin's brother", "Vin's younger brother".
        var ownerIndex: Int?
        var scan = kinIndex - 1
        while scan >= 0, kinshipAdjectives.contains(words[scan].token) { scan -= 1 }
        if scan >= 0, words[scan].isPossessive { ownerIndex = scan }

        // "the brother of Vin".
        if ownerIndex == nil, kinIndex + 2 < words.count, words[kinIndex + 1].token == "of" {
            var candidate = kinIndex + 2
            if ["the", "a", "an"].contains(words[candidate].token), candidate + 1 < words.count {
                candidate += 1
            }
            if isNameLike(words[candidate], at: candidate, vocabulary: vocabulary) {
                ownerIndex = candidate
            }
        }
        guard let ownerIndex else { return howRelated(in: words, vocabulary: vocabulary) }

        let owner = subject(from: [words[ownerIndex]], vocabulary: vocabulary)
        // "Is Reen Vin's brother?" — a yes/no question, which the extractor
        // must not answer with a name.
        if let lead = words.first?.token, ["is", "was", "are", "were", "does", "did"].contains(lead) {
            let between = words[1 ..< ownerIndex].enumerated().first {
                isNameLike($0.element, at: $0.offset + 1, vocabulary: vocabulary)
            }
            if let between {
                return .kinship(
                    subject: owner, relation: relation,
                    other: subject(from: [between.element], vocabulary: vocabulary),
                    form: .yesNo,
                )
            }
        }
        return .kinship(subject: owner, relation: relation, other: nil, form: .whoIs)
    }

    /// "How are X and Y related?" — no possessive and no relation noun, but
    /// unmistakably a kinship question, and the two names are what to search
    /// for together.
    static func howRelated(in words: [QuestionWord], vocabulary: Vocabulary) -> QuestionKind? {
        let tokens = words.map(\.token)
        guard tokens.first == "how", tokens.contains("related") || tokens.contains("relation")
        else { return nil }
        let names = words.enumerated()
            .filter { isNameLike($0.element, at: $0.offset, vocabulary: vocabulary) }
            .map(\.element)
        guard names.count >= 2 else { return nil }
        return .kinship(
            subject: subject(from: [names[0]], vocabulary: vocabulary),
            relation: nil,
            other: subject(from: [names[1]], vocabulary: vocabulary),
            form: .howRelated,
        )
    }

    // MARK: Identity

    /// The openings that mean "tell me who this is". Longest first, so
    /// "tell me about" is not read as nothing.
    static let identityLeadIns: [[String]] = [
        ["tell", "me", "about"], ["tell", "me", "who"],
        ["who", "exactly", "is"], ["who", "is"], ["who", "was"],
        ["who", "are"], ["who", "were"],
        ["what", "is"], ["what", "was"], ["what", "are"], ["what", "were"],
    ]

    /// Filler that trails an identity question without being part of the name.
    static let identityTrailers: Set<String> = [
        "so", "far", "really", "actually", "exactly", "again", "please",
        "in", "the", "this", "book", "story", "novel", "anyway",
    ]

    /// The most content words a subject can be before this stops being a
    /// question about a person and starts being a question about a situation.
    static let maximumSubjectTokens = 4

    static func identity(in words: [QuestionWord], vocabulary: Vocabulary) -> QuestionKind? {
        let tokens = words.map(\.token)
        guard let leadIn = identityLeadIns.first(where: { tokens.starts(with: $0) })
        else { return nil }

        var rest = Array(words.dropFirst(leadIn.count))
        while let first = rest.first, ["the", "a", "an"].contains(first.token) { rest.removeFirst() }
        while let last = rest.last, identityTrailers.contains(last.token) { rest.removeLast() }
        guard !rest.isEmpty else { return nil }
        // A possessive means the question is about somebody's *something*
        // ("What is Alice's cat called?"), not about who somebody is.
        guard !rest.contains(where: \.isPossessive) else { return nil }

        let content = rest.filter { !QueryTerms.stopWords.contains($0.token) && $0.token.count > 1 }
        guard !content.isEmpty, content.count <= maximumSubjectTokens else { return nil }
        // "Who is the brother?" names nobody: requiring `brother` of every
        // passage would be a search dressed up as a name lookup, and BM25 with
        // the kinship expansion is the better answer to it.
        guard content.contains(where: { KinRelation.matching($0.token) == nil }) else { return nil }

        let candidate = subject(from: content, vocabulary: vocabulary)
        // Capitalised, known to the book, or the only word in the question:
        // anything else ("Who is the man in the boat?") is a search, not a
        // name, and the general path handles it better.
        let capitalised = content.contains(where: \.isCapitalised)
        guard capitalised || candidate.isKnownName || content.count == 1 else { return nil }
        return .identity(candidate)
    }

    // MARK: General

    /// A subject for an ordinary question: whoever owns the possessive, else
    /// the first word the book or the tagger calls a person.
    ///
    /// Never bare capitalisation. "Is Alice British?" would otherwise search
    /// for `british` as a required token and find nothing.
    static func generalSubject(in words: [QuestionWord], vocabulary: Vocabulary) -> Subject? {
        if let owner = words.first(where: \.isPossessive) {
            return subject(from: [owner], vocabulary: vocabulary)
        }
        if let found = words.first(where: { vocabulary.isName($0.token) }) {
            // A known name may be a phrase: "White Rabbit" is one subject, not
            // two, and requiring only "white" retrieves the wrong paragraphs.
            let phrase = knownPhrase(startingAt: found, in: words, vocabulary: vocabulary)
            return subject(from: phrase, vocabulary: vocabulary)
        }
        return nil
    }

    /// The longest run of words from `first` that the name table knows as one
    /// name.
    static func knownPhrase(
        startingAt first: QuestionWord, in words: [QuestionWord], vocabulary: Vocabulary,
    ) -> [QuestionWord] {
        guard let start = words.firstIndex(of: first) else { return [first] }
        var best = [first]
        var phrase = [first]
        var index = start + 1
        while index < words.count, phrase.count < 3 {
            phrase.append(words[index])
            if vocabulary.known.contains(phrase.map(\.token).joined(separator: " ")) {
                best = phrase
            }
            index += 1
        }
        return best
    }

    // MARK: Building a subject

    static func subject(from words: [QuestionWord], vocabulary: Vocabulary) -> Subject {
        let tokens = words.map(\.token).filter { !$0.isEmpty }
        let phrase = tokens.joined(separator: " ")
        return Subject(
            display: words.map(\.display).joined(separator: " "),
            tokens: tokens,
            isKnownName: vocabulary.isKnownName(phrase, tokens: tokens),
        )
    }

    /// Whether this word could be naming somebody: the book knows it, the
    /// tagger tagged it, or it is capitalised somewhere other than the start of
    /// the question.
    static func isNameLike(_ word: QuestionWord, at index: Int, vocabulary: Vocabulary) -> Bool {
        guard !QueryTerms.stopWords.contains(word.token), word.token.count > 1 else { return false }
        guard !QueryTerms.capitalisedNonNames.contains(word.token) else { return false }
        if vocabulary.isName(word.token) { return true }
        return word.isCapitalised && index > 0
    }
}
