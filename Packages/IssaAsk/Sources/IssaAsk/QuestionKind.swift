import Foundation

/// Who or what a question is *about*, in the form retrieval can use.
///
/// The tokens are what the FTS pattern is built from, so they are folded and
/// stripped of the possessive: the reader who types "Ryn's" is asking about
/// `ryn`, and a pattern built from `ryn's` reaches nothing — SQLite's tokeniser
/// reads the apostrophe as a word break, which is the bug that made
/// "What is the name of Ryn's brother?" search for `ryn OR s`.
public struct Subject: Sendable, Hashable {
    /// The subject as the reader wrote it, articles removed: "White Rabbit",
    /// "Ryn", "the Duchess" → "Duchess". Shown nowhere; used to compose the
    /// deterministic kinship answer, which has to spell the name their way.
    public var display: String
    /// Folded, lowercased, possessive-stripped. Every one of these is required
    /// of a passage before it is even considered.
    public var tokens: [String]
    /// Whether the book's own name table recognises this, which is the only
    /// reliable signal for an invented name: `NLTagger` tags neither "RYN" nor
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

    /// The relations a question can name, read out of `Kinship`.
    ///
    /// The spellings are here because a group cannot supply them — a brother
    /// and a sister are one group and two relations — but the *group* is not,
    /// and neither is the vocabulary. Walking `Kinship.all` is what makes the
    /// two agree: a relation exists exactly where a group has a word for it,
    /// so there is no `?? forms` fallback for a relation in no group, because
    /// there can no longer be one. The previous shape had that fallback and it
    /// never fired, while the two lists disagreed in both directions anyway.
    ///
    /// Order follows the groups, which is safe because `matching` compares
    /// whole spellings rather than prefixes — "grandmother" is not a form of
    /// "mother" — and `QuestionKindTests` asserts no spelling names two
    /// relations, so there is nothing for an order to decide.
    public static let all: [KinRelation] = {
        let spellings: [String: [String]] = [
            "grandmother": ["grandmother", "grandmothers", "grandma"],
            "grandfather": ["grandfather", "grandfathers", "grandpa"],
            "grandparent": ["grandparent", "grandparents"],
            "granddaughter": ["granddaughter", "granddaughters"],
            "grandson": ["grandson", "grandsons"],
            "grandchild": ["grandchild", "grandchildren"],
            "brother": ["brother", "brothers"],
            "sister": ["sister", "sisters"],
            "sibling": ["sibling", "siblings"],
            "mother": ["mother", "mothers", "mum", "mama", "mamma"],
            "father": ["father", "fathers", "papa", "dad"],
            "parent": ["parent", "parents"],
            "son": ["son", "sons"],
            "daughter": ["daughter", "daughters"],
            "child": ["child", "children", "baby", "babies"],
            "husband": ["husband", "husbands"],
            "wife": ["wife", "wives"],
            "spouse": ["spouse", "spouses"],
            "widow": ["widow", "widows", "widower", "widowers"],
            "aunt": ["aunt", "aunts"],
            "uncle": ["uncle", "uncles"],
            "niece": ["niece", "nieces"],
            "nephew": ["nephew", "nephews"],
            "cousin": ["cousin", "cousins"],
            "relative": ["relative", "relatives", "relation", "relations", "kin"],
            "family": ["family", "families"],
            "friend": ["friend", "friends", "friendship"],
            "companion": ["companion", "companions"],
        ]
        return Kinship.all.flatMap { group in
            group.compactMap { word in
                spellings[word].map { KinRelation(word: word, forms: $0, group: group) }
            }
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
/// the Epilogue: "What is the name of Ryn's brother?" ranked the sentence that
/// says "Her brother, Dask, had trained her…" fiftieth in a pool capped at
/// forty, and the model — handed six passages, five of which never said "Ryn" —
/// answered "Sorrel". Knowing the question is a kinship question is what lets
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

/// What this book calls people, as far as the reader has got.
///
/// Two lists rather than one, because they fail in opposite directions.
/// `NLTagger` finds ordinary names and misses every invented one — it tags
/// neither "RYN" nor "Duchess" nor "White Rabbit" — while the book's own table
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
        // The one choke point both lists funnel through, so `QueryTerms.bookRoles`
        // is enforced here rather than at each of the three call sites. Gutenberg
        // prints "**Author**: Benjamin Franklin" on its own header page, so
        // `author` really is in a Franklin index's name table — and without this
        // the book's own boilerplate teaches the classifier that "the author" is
        // somebody it has met.
        guard !QueryTerms.isBookRole(token) else { return false }
        return tagged.contains(token) || known.contains(token)
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
    /// Contractions that hide an identity lead-in. "Who's Ryn?" is "Who is
    /// Ryn?", and reading it as one word loses the whole question shape.
    static let expansions: [String: [String]] = [
        "who's": ["who", "is"], "what's": ["what", "is"],
        "whos": ["who", "is"], "whats": ["what", "is"],
    ]

    /// Splits the sanitised question into words the classifier can reason
    /// about.
    ///
    /// Through `Words`, which is also what splits the book's own sentences.
    /// The two used to be separate functions differing in one character, and
    /// `KinshipExtractor` compares their output against each other — see the
    /// header of `Words`.
    static func words(in question: String) -> [Words.Word] {
        var out: [Words.Word] = []
        for chunk in question.split(whereSeparator: \.isWhitespace) {
            let display = String(chunk).trimmingCharacters(in: Words.edgePunctuation)
            // "Who's Ryn?" is two words, and only the split form reaches the
            // "who is" lead-in the identity path matches on.
            if let expanded = expansions[display.lowercased()] {
                for part in expanded {
                    out.append(Words.Word(
                        display: part, token: part, isPossessive: false,
                        isCapitalised: false, followedByComma: false,
                    ))
                }
                continue
            }
            guard let word = Words.word(from: String(chunk)) else { continue }
            out.append(word)
        }
        return out
    }

    // MARK: - Classifying

    /// What the classifier decided, and the text it decided it on.
    ///
    /// The second half exists because the spoiler gate has to check the same
    /// words. `nameCandidates` read the whole question while the classifier had
    /// already thrown the aside away, so "wait who is Marek again? Is he one of
    /// the Wardens?" retrieved Marek's introduction and was then refused for a
    /// word out of a clause nothing had been retrieved for. The gate cannot
    /// simply always take the clause either: a question whose opening clause
    /// claims nothing is decided whole, and must be checked whole.
    struct Reading {
        var kind: QuestionKind
        /// The text `kind` was read from — the leading clause when the clause
        /// claimed the kind, the whole question otherwise.
        var text: String
    }

    /// The question's shape, and what it was read from.
    ///
    /// Order matters. Recap first, because it has no subject at all; kinship
    /// before identity, because "Who is Alice's sister?" is both a "who is"
    /// question and a kinship one and only the kinship reading finds the
    /// sentence that answers it.
    ///
    /// **The leading clause decides, and the whole question is consulted only
    /// when the leading clause claims nothing.** A reader who has lost the
    /// thread does not type one clean sentence. Measured against a full-length
    /// novel: "wait who is corran again? he's aldric's brother right? but isn't he one
    /// of the ministry people" was read as a kinship question about `aldric`,
    /// so retrieval hunted family words near Aldric and returned his two
    /// earliest mentions. The Ministry storyline the reader was asking about was
    /// never retrieved; four settings answered "The story hasn't revealed that
    /// yet" about a character named 157 times in what that reader had read. It
    /// scored 2.04/10, the worst of the ten questions in the trial. The aside is
    /// the reader checking their own memory, not the question — and the question
    /// is the clause they opened with.
    ///
    /// Each of the four steps records its own `text`, rather than a rule
    /// deriving one afterwards from the kind: *which* step returned is exactly
    /// what "the text the classifier decided on" means, and a kind alone cannot
    /// tell the clause-decided kinship reading from the fall-through one.
    static func read(_ question: String, vocabulary: Vocabulary) -> Reading {
        guard !QueryTerms.isRecapQuestion(question) else {
            return Reading(kind: .recap, text: question)
        }
        // Stripped once, here, for every reading below. The leading clause is
        // re-tokenised from its own substring, so it carries its own hesitation
        // and has to be stripped separately.
        let words = droppingLeadingFillers(Self.words(in: question))
        guard !words.isEmpty else { return Reading(kind: .general(nil), text: question) }
        let clause = leadingClauseText(of: question)
        let leading = clause.map { droppingLeadingFillers(Self.words(in: $0)) } ?? words

        if let kinship = kinship(in: leading, vocabulary: vocabulary) {
            return Reading(kind: kinship, text: clause ?? question)
        }
        if let identity = identity(in: leading, vocabulary: vocabulary),
           case let .identity(subject) = identity,
           namesOneSubject(subject, vocabulary: vocabulary) {
            return Reading(kind: identity, text: clause ?? question)
        }
        if let kinship = kinship(in: words, vocabulary: vocabulary) {
            return Reading(kind: kinship, text: question)
        }
        if let identity = identity(in: words, vocabulary: vocabulary) {
            return Reading(kind: identity, text: question)
        }
        return Reading(
            kind: .general(generalSubject(in: words, vocabulary: vocabulary)), text: question,
        )
    }

    /// The question's shape, for a caller with no use for the text it came
    /// from — which is every caller but `QueryTerms.extract` and the tests.
    static func kind(of question: String, vocabulary: Vocabulary) -> QuestionKind {
        read(question, vocabulary: vocabulary).kind
    }

    /// Whether an identity subject names one thing, rather than stitching two
    /// together across a connector.
    ///
    /// "who is dask to ryn again? her brother?" reads, on its leading clause
    /// alone, as an identity question about `["dask", "ryn"]` — and a two-token
    /// subject is required of every passage *together*, so retrieval kept the
    /// paragraphs that name both and lost every sentence that says what Dask was
    /// to her. Every answer in a sixteen-arm run then named the wrong man as her
    /// brother. It is a kinship question wearing an identity question's clothes,
    /// and the reader's own next clause says which.
    ///
    /// Counting known names rather than tokens, because a real multi-word name
    /// has one: the index knows "rabbit", not "white". And a subject rejected
    /// here is not thrown away — it falls through to the whole-question reading,
    /// which for a one-clause question is the same words and so the same answer.
    /// Only a question with a later clause can be re-read by this.
    static func namesOneSubject(_ subject: Subject, vocabulary: Vocabulary) -> Bool {
        subject.tokens.filter(vocabulary.known.contains).count < 2
    }

    /// The question's first sentence, or nil when the question is one sentence.
    ///
    /// Split with `SentenceSplitter`, which is the splitter the book's own
    /// sentences go through, so "Who is Mr. Darcy's sister?" is one clause here
    /// for the same reason it is one sentence there. A second spelling of "where
    /// does a sentence end" is how "Mr." becomes a clause boundary.
    ///
    /// **Nil rather than the whole question**, so the caller can tell the two
    /// apart — the spoiler gate checks the clause when there is one and the
    /// whole question when there is not, and a clause equal to the question is
    /// indistinguishable from no clause. Classification of a one-sentence
    /// question therefore runs on the caller's own array, unchanged from before
    /// any of this existed. Every case in `QuestionKindTests` and every fixture
    /// question is one sentence, which is what makes the four-step order above
    /// safe to ship: it can only change a question with a second sentence to be
    /// wrong about.
    ///
    /// Commas are deliberately not clause boundaries. Splitting on them too
    /// would reach more of the questions readers type, and it would cost exactly
    /// the property this paragraph is about.
    static func leadingClauseText(of question: String) -> String? {
        let sentences = SentenceSplitter.ranges(in: question)
        guard sentences.count > 1, let first = sentences.first else { return nil }
        return (question as NSString).substring(with: first)
    }

    // MARK: Kinship

    /// Adjectives a reader puts between the owner and the relation. Without
    /// these "Ryn's younger brother" loses its owner and becomes a general
    /// question about brothers.
    static let kinshipAdjectives: Set<String> = [
        "own", "elder", "older", "younger", "little", "big", "twin", "half",
        "only", "dear", "beloved", "poor", "eldest", "youngest", "step",
    ]

    static func kinship(in words: [Words.Word], vocabulary: Vocabulary) -> QuestionKind? {
        guard let kinIndex = words.firstIndex(where: { KinRelation.matching($0.token) != nil })
        else { return howRelated(in: words, vocabulary: vocabulary) }
        let relation = KinRelation.matching(words[kinIndex].token)

        // "Ryn's brother", "Ryn's younger brother".
        var ownerIndex: Int?
        var scan = kinIndex - 1
        while scan >= 0, kinshipAdjectives.contains(words[scan].token) { scan -= 1 }
        // The possessive alone is not enough. "Who is the author's father?"
        // made `author` the owner, so every passage had to contain the word,
        // and a Gutenberg memoir answered from its own boilerplate — see
        // `QueryTerms.bookRoles`. Rejecting the owner drops through to the
        // general path, which ranks the kinship group and finds Josiah.
        if scan >= 0, words[scan].isPossessive, !QueryTerms.isBookRole(words[scan].token) {
            ownerIndex = scan
        }

        // "the brother of Ryn".
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
        // "Is Dask Ryn's brother?" — a yes/no question, which the extractor
        // must not answer with a name.
        //
        // `ownerIndex > 1`, because the owner can be the very first word: a
        // question that *opens* with a possessive gives `ownerIndex == 0`, and
        // `words[1 ..< 0]` is a trap, not an empty slice. `Was' brother Dask?`
        // reached it — `edgePunctuation` deliberately keeps a trailing
        // apostrophe, because that is what says "Vins'" is possessive, and
        // `possessiveSuffixes` includes `s'`. A typed question crashed the app.
        if ownerIndex > 1, let lead = words.first?.token,
           ["is", "was", "are", "were", "does", "did"].contains(lead) {
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
    static func howRelated(in words: [Words.Word], vocabulary: Vocabulary) -> QuestionKind? {
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

    /// Filler that opens a question without being part of it, mirroring
    /// `identityTrailers` at the other end.
    ///
    /// A reader interrupting their own reading writes "wait who is corran
    /// again?", and the lead-in table is matched against the *start* of the
    /// question, so one word of hesitation is the difference between a name
    /// lookup and a BM25 search over the whole sentence.
    ///
    /// `well` and `right` are deliberately absent. Both are ordinary nouns, and
    /// a word in this set is dropped from the front of every question that opens
    /// with it — including the reader asking what the well is.
    static let leadingFillers: Set<String> = [
        "wait", "ok", "okay", "um", "uh", "hmm", "hey", "so", "and", "but",
        "also", "sorry", "actually",
    ]

    /// The question with its hesitation taken off the front.
    ///
    /// Once, in `read(_:vocabulary:)`, rather than inside the identity reading
    /// where it used to live. Every other reading looks at a *position*: the
    /// yes/no scan reads the first word to find its copula, `howRelated` for
    /// "how", and `isNameLike` exempts index zero because every question
    /// capitalises its first word. A filler left in front of the question moves
    /// all three by one, so "wait is Dask Ryn's brother?" was read as `.whoIs`
    /// and answered "Ryn's brother is Dask." to a question that asked whether he
    /// was. `Words.word(from:)` has already trimmed edge punctuation, so "so,"
    /// strips like "so".
    static func droppingLeadingFillers(_ words: [Words.Word]) -> [Words.Word] {
        var words = words
        while let first = words.first, leadingFillers.contains(first.token) {
            words.removeFirst()
        }
        return words
    }

    /// The most content words a subject can be before this stops being a
    /// question about a person and starts being a question about a situation.
    static let maximumSubjectTokens = 4

    static func identity(in words: [Words.Word], vocabulary: Vocabulary) -> QuestionKind? {
        // The hesitation is already off the front: `read` strips it for
        // every reading, because the lead-in table is matched against the start
        // of the question and "wait who is corran again?" reaches no lead-in at
        // all while it is still there.
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

        // `bookRoles` dropped here rather than rejected outright, so "Who is
        // the author of Frankenstein?" still asks about Frankenstein while
        // "Who is the author?" is left with nothing and falls through to the
        // general path — which is the sensible degradation, rather than a name
        // lookup for a word that names nobody the book introduced.
        let content = rest.filter {
            !QueryTerms.stopWords.contains($0.token) && $0.token.count > 1
                && !QueryTerms.isBookRole($0.token)
        }
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
    static func generalSubject(in words: [Words.Word], vocabulary: Vocabulary) -> Subject? {
        // Never a `bookRoles` owner: "What happened to the author's son?" is
        // the reported bug, and the possessive is what made `author` the
        // subject every passage had to contain.
        if let owner = words.first(where: {
            $0.isPossessive && !QueryTerms.isBookRole($0.token)
        }) {
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
        startingAt first: Words.Word, in words: [Words.Word], vocabulary: Vocabulary,
    ) -> [Words.Word] {
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

    static func subject(from words: [Words.Word], vocabulary: Vocabulary) -> Subject {
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
    static func isNameLike(_ word: Words.Word, at index: Int, vocabulary: Vocabulary) -> Bool {
        guard !QueryTerms.stopWords.contains(word.token), word.token.count > 1 else { return false }
        guard !QueryTerms.capitalisedNonNames.contains(word.token) else { return false }
        // "the Author" is capitalised in plenty of prefaces, and the
        // capitalisation clause below would take it for a name on that alone.
        // See `QueryTerms.bookRoles`.
        guard !QueryTerms.isBookRole(word.token) else { return false }
        if vocabulary.isName(word.token) { return true }
        return word.isCapitalised && index > 0
    }
}
