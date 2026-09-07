import Foundation

/// One sentence that says something, and the window the model is shown it in.
///
/// The unit of retrieval used to be a paragraph, and that is what went wrong.
/// Asked "Who is Vin?" at the Epilogue of a real book, BM25 returned the six
/// paragraphs that said her name most often — which are action scenes, not
/// introductions — and the model stitched a biography out of the nouns standing
/// near her. Asked for her brother's name, the one sentence in the book that
/// says "Her brother, Reen, had trained her…" sat at rank 50 of a pool capped
/// at 40, and the answer was "Quellion".
///
/// A sentence that predicates something of the subject is a different object
/// from a paragraph that mentions it, and the difference is the whole feature.
public struct Evidence: Sendable, Hashable {
    /// Why this sentence was kept, which is also the order it is kept in.
    public enum Role: Sendable, Hashable {
        /// The first sentence in an early passage that names the subject.
        /// Novels introduce people where they first appear.
        case firstMention
        /// The sentence says X *was* something, or calls X something.
        case predicate
        /// The sentence uses a family word about X.
        case kinship
        /// A whole passage, for the general path and for topping up.
        case passage
    }

    /// What the model is shown: the sentence, and where the antecedent matters
    /// the sentence before it. Real chapter offsets, so it is still a location
    /// in the book and still inside the boundary.
    public var excerpt: Passage
    /// The sentence the evidence rests on, in chapter coordinates.
    public var sentence: NSRange
    public var role: Role
    /// The sentence's own text.
    public var sentenceText: String
    /// The sentence before it in the same passage — the whole of the reach the
    /// kinship extractor is allowed, and deliberately one sentence: over-reach
    /// is a confident wrong answer with a citation on it.
    public var precedingText: String?

    public init(
        excerpt: Passage,
        sentence: NSRange,
        role: Role,
        sentenceText: String,
        precedingText: String? = nil,
    ) {
        self.excerpt = excerpt
        self.sentence = sentence
        self.role = role
        self.sentenceText = sentenceText
        self.precedingText = precedingText
    }
}

// MARK: -

/// Picks the sentences that say something about the subject.
///
/// "FTS narrows, sentences decide." The store has already returned a bounded,
/// book-ordered set of passages that must contain the subject; this splits only
/// those, so the cost is a function of how often the subject is named rather
/// than of how long the book is. A 300,000-word novel costs the same as a
/// 90,000-word one.
public enum EvidenceFinder {
    /// Every number the finder has an opinion about.
    public enum Limits {
        /// How many of the earliest passages contribute a first mention. Six,
        /// because a character is introduced once and referred to for ever
        /// after, and the introduction is what "who is X" is asking for.
        public static let firstMentionPassages = 6
        /// How many sentences that predicate something of X are kept.
        public static let predicateSentences = 10
        /// The ceiling on identity excerpts. Twelve sentence-windows of about
        /// sixty words is roughly 950 tokens — comfortably inside the budget,
        /// and about half what six paragraphs cost.
        public static let identityExcerpts = 12
        /// How many kin sentences are kept.
        public static let kinshipSentences = 8
    }

    // MARK: - Identity

    /// The sentences that introduce X and the sentences that say what X is.
    ///
    /// - Parameter passages: bounded, in book order, every one containing the
    ///   subject. Book order is what makes the store's `LIMIT` keep the
    ///   introductions instead of the action scenes.
    public static func identity(
        subject: Subject, in passages: [RetrievedPassage],
    ) -> [Evidence] {
        let patterns = Patterns(subject: subject)
        var firstMentions: [Evidence] = []
        var predicates: [Evidence] = []

        for passage in passages {
            if firstMentions.count >= Limits.firstMentionPassages,
               predicates.count >= Limits.predicateSentences { break }
            let sentences = split(passage)
            var namedInThisPassage = false
            for (index, sentence) in sentences.enumerated() {
                guard patterns.mentions(sentence.text) else { continue }
                if !namedInThisPassage {
                    namedInThisPassage = true
                    if firstMentions.count < Limits.firstMentionPassages {
                        // Plus the sentence after it: an introduction is
                        // regularly "X came in. She was the smith's daughter."
                        firstMentions.append(evidence(
                            sentences, from: index, key: index,
                            through: min(index + 1, sentences.count - 1),
                            in: passage, role: .firstMention,
                        ))
                    }
                }
                guard predicates.count < Limits.predicateSentences,
                      patterns.saysSomethingAbout(sentence.text) else { continue }
                predicates.append(evidence(
                    sentences, from: index, key: index, through: index,
                    in: passage, role: .predicate,
                ))
            }
        }
        // First mentions first when there is not room for everything, then back
        // into book order — the instructions tell the model the excerpts are in
        // reading order, and a model handed events out of sequence invents a
        // chronology to explain them.
        return inBookOrder(Array((firstMentions + predicates).prefix(Limits.identityExcerpts)))
    }

    // MARK: - Kinship

    /// Sentences using a family word about X.
    ///
    /// The subject must be named in the sentence itself or in the one
    /// immediately before it, and when it is the one before, that sentence
    /// comes into the window — "Vin had been raised on the streets. Her
    /// brother, Reen, had trained her" only answers the question with both
    /// halves present.
    public static func kinship(
        subject: Subject, relation: KinRelation?, in passages: [RetrievedPassage],
        limit: Int = Limits.kinshipSentences,
    ) -> [Evidence] {
        let patterns = Patterns(subject: subject)
        guard let kin = Patterns.kinExpression(for: relation) else { return [] }
        var found: [Evidence] = []

        for passage in passages {
            let sentences = split(passage)
            for (index, sentence) in sentences.enumerated() {
                guard patterns.matches(kin, sentence.text) else { continue }
                let namesHere = patterns.mentions(sentence.text)
                let namesBefore = index > 0 && patterns.mentions(sentences[index - 1].text)
                guard namesHere || namesBefore else { continue }
                found.append(evidence(
                    sentences, from: namesHere ? index : index - 1, key: index, through: index,
                    in: passage, role: .kinship,
                ))
                if found.count == limit { return inBookOrder(found) }
            }
        }
        return inBookOrder(found)
    }

    // MARK: - Whole passages

    /// Passages as they come, for the general path and for topping up a
    /// kinship question that found too little.
    public static func passages(_ ranked: [PassageRanker.Ranked]) -> [Evidence] {
        ranked.map {
            Evidence(
                excerpt: $0.passage,
                sentence: $0.passage.range,
                role: .passage,
                sentenceText: $0.passage.displayText,
            )
        }
    }

    /// Back into the shape the prompt builder and the sheet already speak.
    public static func ranked(_ evidence: [Evidence]) -> [PassageRanker.Ranked] {
        evidence.map {
            PassageRanker.Ranked(
                retrieved: RetrievedPassage(passage: $0.excerpt, bm25: 0, isTruncated: false),
                score: 0,
            )
        }
    }

    // MARK: - Sentences

    /// One sentence of one passage, in both coordinate systems it needs.
    struct Sentence: Sendable {
        /// Within the passage's own text.
        var local: NSRange
        /// In the chapter, which is where the boundary lives.
        var chapter: NSRange
        var text: String
    }

    static func split(_ retrieved: RetrievedPassage) -> [Sentence] {
        let string = retrieved.passage.text as NSString
        let whole = NSRange(location: 0, length: string.length)
        return SentenceSplitter.ranges(in: string, range: whole).map { local in
            Sentence(
                local: local,
                chapter: NSRange(
                    location: retrieved.passage.start + local.location, length: local.length,
                ),
                text: string.substring(with: local),
            )
        }
    }

    /// Lowercased and diacritics folded, for matching only — never for offsets,
    /// because folding can change a string's length.
    ///
    /// Called for the sentences that pass the cheap guard in
    /// `Patterns.mentions` and nowhere else. Folding every sentence up front
    /// measured at 33 ms on a 300,000-word book: an allocation and a Unicode
    /// transform for two and a half thousand strings, almost none of which have
    /// anything to do with the question.
    static func fold(_ text: String) -> String {
        text.folding(
            options: [.diacriticInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US"),
        )
    }

    /// Builds one piece of evidence out of a run of sentences.
    ///
    /// The window's `start` and `end` are real chapter offsets, so the excerpt
    /// is a location in the book rather than a quotation floating free of it —
    /// and its text is the chapter's own characters at exactly that range.
    static func evidence(
        _ sentences: [Sentence],
        from: Int,
        key: Int,
        through: Int,
        in retrieved: RetrievedPassage,
        role: Evidence.Role,
    ) -> Evidence {
        let string = retrieved.passage.text as NSString
        let first = sentences[max(0, min(from, sentences.count - 1))]
        let last = sentences[max(0, min(through, sentences.count - 1))]
        let local = NSRange(
            location: first.local.location,
            length: max(first.local.length, NSMaxRange(last.local) - first.local.location),
        )
        let text = string.substring(with: local)
        let excerpt = Passage(
            spineIndex: retrieved.passage.spineIndex,
            ordinal: retrieved.passage.ordinal,
            start: retrieved.passage.start + local.location,
            end: retrieved.passage.start + NSMaxRange(local),
            words: PassageChunker.wordCount(text),
            text: text,
        )
        return Evidence(
            excerpt: excerpt,
            sentence: sentences[key].chapter,
            role: role,
            sentenceText: sentences[key].text,
            precedingText: key > 0 ? sentences[key - 1].text : nil,
        )
    }

    /// Reading order, with anything already inside an earlier window dropped.
    ///
    /// Two overlapping windows are the same text twice, numbered as two
    /// excerpts — which spends the budget twice and invites the model to cite
    /// one fact as two sources.
    static func inBookOrder(_ evidence: [Evidence]) -> [Evidence] {
        // Keyed on the spine index as well as the range, because `sentence` is
        // an offset *within its chapter*. Two chapters that open with sentences
        // of the same length start at the same location with the same length,
        // so the set called them the same sentence and threw one away — and the
        // one it threw away could be the only evidence there was. The loop
        // below already checks the spine index; only the set did not.
        var seen = Set<[Int]>()
        let unique = evidence.filter {
            seen.insert([$0.excerpt.spineIndex, $0.sentence.location, $0.sentence.length])
                .inserted
        }
        let ordered = unique.sorted {
            ($0.excerpt.spineIndex, $0.excerpt.start) < ($1.excerpt.spineIndex, $1.excerpt.start)
        }
        var kept: [Evidence] = []
        for piece in ordered {
            if let last = kept.last, last.excerpt.spineIndex == piece.excerpt.spineIndex,
               piece.sentence.location < last.excerpt.end {
                continue
            }
            kept.append(piece)
        }
        return kept
    }
}

// MARK: -

/// The regular expressions one question needs, compiled once.
///
/// Once per question, never per sentence: a 300-passage scan is a couple of
/// thousand sentences, and `NSRegularExpression(pattern:)` in that loop would
/// cost more than the scan it is part of. The cheap `contains` guard in
/// `mentions` comes first for the same reason — most sentences of a passage do
/// not name the subject at all, and a substring search settles that in
/// nanoseconds.
struct Patterns: Sendable {
    let head: String
    let mention: NSRegularExpression?
    let predicates: [NSRegularExpression]

    init(subject: Subject) {
        let tokens = subject.tokens.filter { !$0.isEmpty }
        head = tokens.last ?? ""
        // A multi-word name is used in full once and by its head thereafter:
        // "a White Rabbit with pink eyes" becomes "the Rabbit" three lines
        // later, and only the second form is in most of the sentences.
        let spelled = tokens.map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "\\s+")
        let alternatives = tokens.count > 1
            ? "(?:\(spelled)|\(NSRegularExpression.escapedPattern(for: head)))"
            : spelled
        mention = tokens.isEmpty ? nil : Patterns.expression("\\b\(alternatives)\\b")

        guard !tokens.isEmpty else {
            predicates = []
            return
        }
        let copulas = "was|is|were|are|had been|became"
        predicates = [
            // "Vin was a Mistborn." / "The Duchess is the one who…"
            "\\b\(alternatives)\\b\\s+(?:\(copulas))\\b",
            // "Vin, the Heir of the Survivor, …"
            "\\b\(alternatives)\\b\\s*,\\s*(?:the|a|an)\\b",
            // "Vin, who had been raised on the streets, …"
            "\\b\(alternatives)\\b\\s*,?\\s+who\\b",
            // "…a girl called Vin." / "…was named Vin." The optional pronoun is
            // there because "the crew called her Vin" is how a book most often
            // says what somebody is called.
            "\\b(?:was|is|called|named)\\s+(?:him|her|them|it|the|a|an)?\\s*\(alternatives)\\b",
        ].compactMap(Patterns.expression)
    }

    static func expression(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// One expression over every spelling of every relation, or over the
    /// asked-about group when the question named one.
    ///
    /// The group rather than the word, because a novel introduces a brother
    /// once and then uses his name: the sentence a reader is asking about may
    /// say "sibling" or "sister" and never "brother".
    static func kinExpression(for relation: KinRelation?) -> NSRegularExpression? {
        let words = relation.map { Set($0.forms).union($0.group) } ?? Set(KinRelation.allForms)
        guard !words.isEmpty else { return nil }
        let alternation = words.sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        // Case-insensitive rather than folded, so this can run on the book's own
        // text: family words carry no diacritics, and folding every sentence to
        // find them costs more than the search does.
        return try? NSRegularExpression(
            pattern: "\\b(?:\(alternation))\\b", options: [.caseInsensitive],
        )
    }

    /// Whether this sentence names the subject.
    ///
    /// - Parameter sentence: the book's own text, unfolded. The guard runs
    ///   first and rejects most sentences without allocating anything; only
    ///   what survives is folded for the regex.
    func mentions(_ sentence: String) -> Bool {
        guard couldMention(sentence), let mention else { return false }
        return matches(mention, EvidenceFinder.fold(sentence))
    }

    func saysSomethingAbout(_ sentence: String) -> Bool {
        guard couldMention(sentence) else { return false }
        let folded = EvidenceFinder.fold(sentence)
        return predicates.contains { matches($0, folded) }
    }

    /// The cheap half. Most sentences of a passage do not name the subject at
    /// all, and one case- and diacritic-insensitive search settles that without
    /// the folded copy the expressions need.
    func couldMention(_ sentence: String) -> Bool {
        guard !head.isEmpty else { return false }
        return sentence.range(of: head, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        let string = text as NSString
        return expression.firstMatch(
            in: text, options: [], range: NSRange(location: 0, length: string.length),
        ) != nil
    }
}
