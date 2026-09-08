import Foundation
import Testing

@testable import IssaAsk

/// The table that decides which retrieval a question gets.
///
/// It is written against the shapes readers actually type, including the two
/// that failed on the real book: "Who is Ryn?" was answered from passing
/// mentions, and "What is the name of Ryn's brother?" was answered "Sorrel".
/// Both start here — the first has to be an identity question and the second a
/// kinship one, or no amount of later work can find the right sentence.
struct QuestionKindTests {
    static func kind(_ question: String, known: [String] = []) -> QuestionKind {
        QueryTerms.extract(from: question, knownNames: known).kind
    }

    static func subject(_ question: String, known: [String] = []) -> Subject? {
        kind(question, known: known).subject
    }

    // MARK: - Identity

    @Test("who is X, what is the X, tell me about X are identity questions")
    func readsIdentityQuestions() {
        for (question, tokens) in [
            ("Who is Ryn?", ["ryn"]),
            ("Who's Ryn?", ["ryn"]),
            ("Who is the White Rabbit?", ["white", "rabbit"]),
            ("Who is the Duchess?", ["duchess"]),
            ("What is the Ferrant?", ["ferrant"]),
            ("Tell me about Dinah", ["dinah"]),
            ("Who was the Iron Warden really?", ["iron", "warden"]),
        ] {
            let kind = Self.kind(question)
            guard case let .identity(subject) = kind else {
                Issue.record("\(question) classified as \(kind.label)")
                continue
            }
            #expect(subject.tokens == tokens, "\(question)")
        }
    }

    @Test("a question with too much in it is a search, not a name lookup")
    func rejectsLongIdentityRemainders() {
        // "Who is the man in the boat by the river?" is a question about a
        // scene. Requiring every one of those words of a passage finds nothing,
        // and BM25 over all of them finds the scene.
        for question in [
            "Who is the man standing by the river bank waiting?",
            "Who are the main characters so far?",
            "What is the reason she cried so much?",
        ] {
            #expect(Self.kind(question).label == "general", "\(question)")
        }
    }

    @Test("a lower-case single word is still a name lookup")
    func allowsSingleTokenIdentity() {
        // The reader typing in a hurry gets the same retrieval as the reader
        // who capitalises.
        guard case let .identity(subject) = Self.kind("who is ryn?") else {
            Issue.record("expected identity")
            return
        }
        #expect(subject.tokens == ["ryn"])
        #expect(!subject.isKnownName)
        // …and the book's own name table says so when it can.
        guard case let .identity(known) = Self.kind("who is ryn?", known: ["ryn"]) else {
            Issue.record("expected identity")
            return
        }
        #expect(known.isKnownName)
    }

    // MARK: - Kinship

    @Test("the possessive and the relation together make a kinship question")
    func readsKinshipQuestions() {
        for question in [
            "What is the name of Ryn's brother?",
            "Who is Ryn's brother?",
            "Who was Ryn's younger brother?",
            "Who is the brother of Ryn?",
        ] {
            let kind = Self.kind(question)
            guard case let .kinship(subject, relation, other, form) = kind else {
                Issue.record("\(question) classified as \(kind.label)")
                continue
            }
            #expect(subject.tokens == ["ryn"], "\(question)")
            #expect(relation?.word == "brother", "\(question)")
            #expect(other == nil, "\(question)")
            #expect(form == .whoIs, "\(question)")
        }
    }

    @Test("a yes/no kinship question is not one the extractor may answer with a name")
    func readsYesNoKinship() {
        guard case let .kinship(subject, relation, other, form) =
            Self.kind("Is Dask Ryn's brother?", known: ["ryn", "dask"])
        else {
            Issue.record("expected kinship")
            return
        }
        #expect(subject.tokens == ["ryn"])
        #expect(other?.tokens == ["dask"])
        #expect(relation?.word == "brother")
        // Answering "Ryn's brother is Dask." to a question that asked whether
        // he is would be a confident answer to a question nobody asked.
        #expect(form == .yesNo)
    }

    @Test("how are X and Y related is kinship with two subjects and no relation word")
    func readsHowRelated() {
        guard case let .kinship(subject, relation, other, form) =
            Self.kind("How are Ryn and Marek related?", known: ["ryn", "marek"])
        else {
            Issue.record("expected kinship")
            return
        }
        #expect(subject.tokens == ["ryn"])
        #expect(other?.tokens == ["marek"])
        #expect(relation == nil)
        #expect(form == .howRelated)
    }

    @Test("a relation nobody owns falls through to a general search")
    func requiresAnOwner() {
        // "Who is the brother?" has nothing to require of a passage; the
        // ordinary BM25 path with the kinship expansion is the better answer.
        #expect(Self.kind("Who is the brother?").label == "general")
    }

    @Test("every relation reaches its whole group")
    func relationsCarryTheirGroup() {
        let cousin = try? #require(KinRelation.matching("cousins"))
        #expect(cousin?.word == "cousin")
        #expect(cousin?.group.contains("family") == true)
        // Whole spellings, not prefixes: "grandmother" is not a form of
        // "mother", so no ordering has to protect it.
        #expect(KinRelation.matching("grandmother")?.word == "grandmother")
        #expect(KinRelation.matching("rabbit") == nil)
        #expect(KinRelation.allForms.contains("brothers"))
    }

    // MARK: - General

    @Test("a possessive that owns something other than a relative keeps its subject")
    func generalKeepsThePossessiveOwner() {
        // "What is Alice's cat called?" is not a question about cats. Requiring
        // "alice" of every passage is the difference between the paragraph that
        // names Dinah and forty paragraphs that mention a cat.
        guard case let .general(subject) = Self.kind("What is Alice's cat called?") else {
            Issue.record("expected general")
            return
        }
        #expect(subject?.tokens == ["alice"])
    }

    @Test("a general question finds its subject from the tagger or the book's names")
    func generalFindsANamedSubject() {
        #expect(Self.subject("What did Alice drink?")?.tokens == ["alice"])
        #expect(Self.subject("What did the Duchess do?", known: ["duchess"])?.tokens
            == ["duchess"])
        // A multi-word name the book knows stays one subject.
        #expect(Self.subject("What did the White Rabbit drop?", known: ["white rabbit"])?
            .tokens == ["white", "rabbit"])
    }

    @Test("bare capitalisation is not a subject")
    func generalIgnoresOrdinaryCapitals() {
        // "Is Alice British?" would otherwise require `british` of every
        // passage and retrieve nothing at all.
        #expect(Self.subject("Why did she cry so much?") == nil)
    }

    // MARK: - One kinship vocabulary

    @Test(
        "every relation a reader names reaches the kinship path",
        arguments: [
            "relative", "relatives", "relation", "kin", "family",
            "grandparent", "grandparents", "companion", "grandmothers", "wives",
            "widows", "baby", "brother", "cousin", "friend",
        ],
    )
    func everyRelationIsMatched(word: String) {
        // These are the words the two lists disagreed about. "Who is X's
        // relative?" reached BM25 over the whole question instead of the
        // kinship path, and never found the paragraph that says so.
        #expect(KinRelation.matching(word) != nil, "\(word)")
    }

    @Test("a relation's spellings all belong to its own group")
    func spellingsBelongToTheirGroup() {
        for relation in KinRelation.all {
            let outside = relation.forms.filter { !relation.group.contains($0) }
            #expect(outside.isEmpty, "\(relation.word) has \(outside) outside its group")
            #expect(relation.group.contains(relation.word), "\(relation.word)")
        }
    }

    @Test("no spelling names two relations, so the order of the table decides nothing")
    func spellingsNameOneRelation() {
        var owner: [String: String] = [:]
        for relation in KinRelation.all {
            for form in relation.forms {
                if let existing = owner[form] {
                    Issue.record("\(form) is both \(existing) and \(relation.word)")
                }
                owner[form] = relation.word
            }
        }
        // And the whole set is what the query asks for when the reader named no
        // relation at all.
        #expect(Set(KinRelation.allForms) == Set(owner.keys))
    }

    @Test("asking about a relative is a kinship question")
    func relativeIsAKinshipQuestion() {
        for question in [
            "Who is Ryn's relative?", "Who is Ryn's family?",
            "Who is Ryn's grandparent?", "Who is Ryn's companion?",
        ] {
            #expect(Self.kind(question, known: ["ryn"]).label == "kinship", "\(question)")
        }
    }

    // MARK: - Questions that are not questions

    /// A typed question crashed the app.
    ///
    /// `edgePunctuation` deliberately keeps a trailing apostrophe — it is what
    /// says "Vins'" is possessive — and `possessiveSuffixes` includes `s'`. So
    /// a copula ending in *s* followed by an apostrophe is a possessive at word
    /// zero, and the yes/no scan then took `words[1 ..< 0]`, which is a trap
    /// rather than an empty slice.
    @Test(
        "a question that opens with a possessive is classified, not trapped",
        arguments: ["Was' brother Dask?", "Is' brother Dask?", "Does' sister Alice?"],
    )
    func aLeadingPossessiveDoesNotTrap(question: String) {
        // The classification itself is nonsense, because the question is; what
        // matters is that it is a classification and not a crash.
        #expect(Self.kind(question).label == "kinship")
    }

    @Test("a real yes/no question still finds the person being asked about")
    func theYesNoScanStillWorks() {
        let kind = Self.kind("Is Dask Ryn's brother?", known: ["ryn", "dask"])
        guard case let .kinship(subject, relation, other, form) = kind else {
            Issue.record("classified as \(kind.label)")
            return
        }
        #expect(subject.tokens == ["ryn"])
        #expect(relation?.word == "brother")
        #expect(other?.tokens == ["dask"])
        #expect(form == .yesNo)
    }

    // MARK: - Recap

    @Test("recap still wins over everything")
    func recapComesFirst() {
        #expect(Self.kind("What has happened so far?") == .recap)
        #expect(QueryTerms.extract(from: "Summarise the story so far").isRecap)
        #expect(!QueryTerms.extract(from: "Who is Ryn?").isRecap)
    }

    // MARK: - "The author" is not a name

    /// The classification half of the Franklin bug.
    ///
    /// Every retrieval path except the recap requires its subject of every
    /// passage it will consider, so a subject of `author` is a search for the
    /// word "author" dressed up as a name lookup — and in a Gutenberg
    /// non-fiction book that word is in the boilerplate, in the editor's
    /// introduction, and in every "author of *X*".
    @Test("no question can make a word for the book's maker its subject")
    func rolesAreNeverASubject() {
        for question in [
            "What happened to the author's son?",
            "Who is the author's father?",
            "Who is the author?",
            "Tell me about the narrator",
            "How are the author and the editor related?",
            "What does the Poet think?",
        ] {
            let tokens = Self.subject(question)?.tokens ?? []
            #expect(
                tokens.allSatisfy { !QueryTerms.isBookRole($0) },
                "\(question) → subject \(tokens)",
            )
        }
    }

    /// The book's own name table is the trap. Gutenberg prints "Author:
    /// Benjamin Franklin" on its header page, so `author` is a name that index
    /// knows — and the promotion that exists to catch invented names ("Ryn",
    /// "Cheshire") would otherwise catch this one.
    @Test("a role word the index knows as a name is still not a name")
    func aKnownRoleIsStillNotASubject() {
        let kind = Self.kind("Who is the author?", known: ["author", "josiah"])
        #expect(kind.label == "general")
        #expect(kind.subject == nil)
    }

    /// Degrading, not refusing. The question keeps every other word it had, so
    /// a book that really is about an author is still asked about that author.
    @Test("a role word beside a real name leaves the real name as the subject")
    func theRestOfTheQuestionSurvives() {
        let kind = Self.kind("Who is the author of Frankenstein?", known: ["frankenstein"])
        #expect(kind.subject?.tokens == ["frankenstein"])
        // And the kinship reading survives when the owner really is a person.
        let kinship = Self.kind("Who is Josiah's father?", known: ["josiah"])
        #expect(kinship.label == "kinship")
        #expect(kinship.subject?.tokens == ["josiah"])
    }

    // MARK: - The question is the clause it opens with

    /// The worst question in the full-book trial, at 2.04/10.
    ///
    /// The reader has lost the thread and is checking their own memory out loud.
    /// The relation word belongs to the aside, not to what they want to know,
    /// but it was the only one in the question — so retrieval hunted family
    /// words near Aldric and returned his two earliest mentions, and the
    /// Ministry storyline that was actually being asked about was never
    /// retrieved. Four of the settings measured answered "The story hasn't
    /// revealed that yet" about a character named 157 times in what that reader
    /// had already read.
    @Test("a kinship aside does not become the question")
    func aKinshipAsideIsNotTheQuestion() {
        let question = "wait who is corran again? he's aldric's brother right? "
            + "but isn't he one of the ministry people"
        let kind = Self.kind(question, known: ["corran", "aldric"])
        guard case let .identity(subject) = kind else {
            Issue.record("classified as \(kind.label)")
            return
        }
        #expect(subject.tokens == ["corran"])
        #expect(subject.isKnownName)

        // And this is the reading it replaced, kept so that collapsing the four
        // steps back into two fails here rather than in a trial six months from
        // now: read all at once, the question is a kinship question about the
        // wrong person entirely.
        let hijacked = QuestionReader.kinship(
            in: QuestionReader.words(in: question),
            vocabulary: Vocabulary(known: ["corran", "aldric"]),
        )
        #expect(hijacked?.subject?.tokens == ["aldric"])
    }

    /// The other direction, and the reason the leading clause is still tried for
    /// kinship before identity.
    ///
    /// "Who is Ryn's brother?" declines identity on its own — a possessive means
    /// the question is about somebody's *something* — but "Who is the brother of
    /// Ryn?" has no possessive to decline on, and identity would happily take
    /// "brother ryn" for a name. Only the kinship reading finds the sentence.
    @Test("a leading kinship clause still wins")
    func aLeadingKinshipClauseStillWins() {
        for question in [
            "Who is the brother of Ryn?",
            "Who is Ryn's brother? I forget.",
            "Who was Ryn's younger brother? he gets mentioned early on",
        ] {
            let kind = Self.kind(question, known: ["ryn"])
            guard case let .kinship(subject, relation, _, _) = kind else {
                Issue.record("\(question) classified as \(kind.label)")
                continue
            }
            #expect(subject.tokens == ["ryn"], "\(question)")
            #expect(relation?.word == "brother", "\(question)")
        }
    }

    /// A leading clause that claims nothing hands the whole question back.
    ///
    /// Deciding on the leading clause must not mean *ignoring* the rest: a
    /// reader who opens with an apology and then asks a kinship question has
    /// still asked a kinship question.
    /// Found by re-running the measured questions after the leading-clause rule
    /// landed: this one regressed from a correct answer to sixteen wrong ones,
    /// every arm naming a different man as Ryn's brother.
    @Test("a leading clause that names two people is not an identity question")
    func aSubjectStitchedFromTwoNamesIsNotIdentity() {
        // "who is X to Y" asks about a relationship, but on its leading clause
        // alone it reads as identity with a subject of ["dask", "ryn"] — and a
        // two-token subject must appear in a passage *together*, so retrieval
        // kept the paragraphs naming both and lost every sentence that says what
        // Dask was to her.
        let subject = Self.subject(
            "who is dask to ryn again? her brother? and what happened to him",
            known: ["ryn", "dask", "torv", "halden"],
        )
        #expect(subject?.tokens == ["dask"], "the subject is the person asked about")
    }

    @Test("a two-word name is still one subject")
    func aMultiWordNameSurvives() {
        // The guard counts known names, not tokens, because a real multi-word
        // name has one of them: the index knows "rabbit", not "white". And a
        // subject it rejects falls through to the whole-question reading, which
        // for a one-clause question is the same words — so this holds whether or
        // not the index happens to know both halves.
        #expect(Self.subject("Who is the White Rabbit?", known: ["white rabbit", "rabbit"])?
            .tokens == ["white", "rabbit"])
        #expect(Self.subject("Who is the White Rabbit?", known: ["white", "rabbit"])?
            .tokens == ["white", "rabbit"])
    }

    @Test("a kinship question after an aside is still found")
    func aKinshipQuestionAfterAnAsideIsStillFound() {
        let kind = Self.kind("sorry i lost track. who is Ryn's brother?", known: ["ryn"])
        guard case let .kinship(subject, relation, _, _) = kind else {
            Issue.record("classified as \(kind.label)")
            return
        }
        #expect(subject.tokens == ["ryn"])
        #expect(relation?.word == "brother")
    }

    /// …and the same for identity, which is the fourth and last step.
    @Test("an identity question after an aside is still found")
    func anIdentityQuestionAfterAnAsideIsStillFound() {
        #expect(Self.kind("wait. who is Ryn?", known: ["ryn"]).subject?.tokens == ["ryn"])
        #expect(Self.kind("ok. tell me about Dinah").label == "identity")
    }

    /// The property the whole change rests on.
    ///
    /// For a question of one sentence the leading clause *is* the question, so
    /// classification runs on the identical array it ran on before any of this
    /// existed. Every other case in this file and every fixture question is one
    /// sentence, which is why they stay green by construction rather than by
    /// luck — and the honorific is why the clause splitter has to be
    /// `SentenceSplitter` rather than a second opinion about full stops.
    @Test(
        "one sentence is one clause",
        arguments: [
            "Who is Ryn?",
            "Who is Mr. Darcy's sister?",
            "Who was the Iron Warden really?",
            "Is Dask Ryn's brother?",
            "How are Ryn and Marek related?",
            "What is Alice's cat called?",
            "Tell me about Dinah",
            "Who is the man standing by the river bank waiting?",
            "Was' brother Dask?",
        ],
    )
    func oneSentenceIsOneClause(question: String) {
        let sanitised = QueryTerms.sanitise(question)
        #expect(SentenceSplitter.ranges(in: sanitised).count == 1, "\(question)")
        let words = QuestionReader.words(in: sanitised)
        #expect(
            QuestionReader.leadingClause(of: sanitised, words: words) == words,
            "\(question)",
        )
    }

    /// Hesitation at the front of a question is not part of the question.
    @Test("a leading filler is dropped")
    func leadingFillerIsDropped() {
        for question in ["so who is Ryn?", "wait who is Ryn?", "um, who is Ryn?"] {
            let kind = Self.kind(question, known: ["ryn"])
            guard case let .identity(subject) = kind else {
                Issue.record("\(question) classified as \(kind.label)")
                continue
            }
            #expect(subject.tokens == ["ryn"], "\(question)")
        }
        // Deliberately not fillers. A word in the set is dropped from the front
        // of every question that opens with it, and both of these are ordinary
        // nouns a reader can be asking about.
        #expect(!QuestionReader.leadingFillers.contains("well"))
        #expect(!QuestionReader.leadingFillers.contains("right"))
    }
}
