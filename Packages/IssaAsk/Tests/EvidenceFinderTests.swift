import Foundation
import Testing

@testable import IssaAsk

/// Which sentences are handed to the model, and whether they are still a place
/// in the book.
struct EvidenceFinderTests {
    /// A passage as the store would have returned it, with real offsets.
    static func passage(
        _ text: String, spine: Int = 2, ordinal: Int = 0, start: Int = 1_000,
    ) -> RetrievedPassage {
        RetrievedPassage(
            passage: Passage(
                spineIndex: spine, ordinal: ordinal, start: start,
                end: start + (text as NSString).length,
                words: PassageChunker.wordCount(text), text: text,
            ),
            bm25: -1, isTruncated: false,
        )
    }

    static func subject(_ display: String, tokens: [String]) -> Subject {
        Subject(display: display, tokens: tokens, isKnownName: true)
    }

    // MARK: - Identity

    @Test("the first mention of a character comes with the sentence after it")
    func firstMentionCarriesItsFollowUp() {
        let evidence = EvidenceFinder.identity(
            subject: Self.subject("Dask", tokens: ["dask"]),
            in: [Self.passage(
                "The street was empty. Dask came in from the rain. He was her brother, "
                    + "and had trained her since she could walk. Nobody spoke.",
            )],
        )
        let first = try? #require(evidence.first)
        #expect(first?.role == .firstMention)
        // An introduction is regularly two sentences: the arrival, then who
        // they are.
        #expect(first?.excerpt.text.contains("Dask came in") == true)
        #expect(first?.excerpt.text.contains("her brother") == true)
        #expect(first?.excerpt.text.contains("The street was empty") == false)
    }

    @Test("a sentence that predicates something of the subject is kept")
    func keepsPredicateSentences() {
        let patterns = Patterns(subject: Self.subject("Ryn", tokens: ["ryn"]))
        for sentence in [
            "ryn was a ferrant of great skill.",
            "ryn, the heir of the marches, said nothing.",
            "ryn, who had been raised on the streets, waited.",
            "the crew called her ryn from then on.",
            "ryn is the one they follow.",
        ] {
            #expect(patterns.saysSomethingAbout(sentence), "\(sentence)")
        }
        // A sentence that merely has her in it says nothing about her, and six
        // of those is the biography stitched out of passing mentions.
        #expect(!patterns.saysSomethingAbout("ryn ran down the alley and jumped."))
        #expect(!patterns.saysSomethingAbout("the mists closed around them."))
    }

    @Test("a multi-word name is matched by its head as well as in full")
    func matchesTheHeadOfAName() {
        let patterns = Patterns(subject: Self.subject("White Rabbit", tokens: ["white", "rabbit"]))
        #expect(patterns.mentions("a white rabbit with pink eyes ran close by her."))
        // Three lines later the book says "the Rabbit", and only that form is
        // in most of the sentences that say anything about him.
        #expect(patterns.mentions("the rabbit was still in sight, hurrying down it."))
        #expect(!patterns.mentions("the mouse looked at her rather inquisitively."))
        // A single-word subject is not matched by anything but itself.
        let single = Patterns(subject: Self.subject("Ryn", tokens: ["ryn"]))
        #expect(!single.mentions("the vine grew over the wall."))
    }

    @Test("a first mention outranks a predicate even when the book puts it later")
    func firstMentionsOutrankPredicates() throws {
        // Book order and rank order have to disagree or this proves nothing, so:
        // the earlier passage carries an introduction *and* a predicate, and the
        // later one carries a second introduction. In the book the predicate
        // sits in the middle; in the ranking it comes last.
        let evidence = EvidenceFinder.identity(
            subject: Self.subject("Dask", tokens: ["dask"]),
            in: [
                Self.passage(
                    "Dask came back. He waited by the door. Dask was her brother.", spine: 2,
                ),
                Self.passage("Ryn ran. Dask followed her down the alley.", spine: 3),
            ],
        )
        try #require(evidence.count == 3)
        // Reading order for the model…
        #expect(evidence.map(\.role) == [.firstMention, .predicate, .firstMention])
        // …and the finder's own preference written down beside it, so a prompt
        // that will not fit sacrifices the predicate rather than whichever
        // sentence happens to come last in the book.
        #expect(evidence.map(\.priority) == [0, 2, 1])
        let kept = PassageRanker.best(EvidenceFinder.ranked(evidence), count: 2)
        #expect(kept.map(\.passage) == [evidence[0].excerpt, evidence[2].excerpt])
    }

    @Test("a sentence counted twice does not spend two of the excerpts")
    func aDuplicateSentenceDoesNotSpendTheCap() {
        // "Dask was a thief." is the first mention of Dask *and* a sentence
        // that predicates something of him, so it is minted twice, once in each
        // list, resting on the same key sentence. The cap used to be applied to
        // the pair and the duplicate thrown away afterwards, which is how a
        // constant reading fifteen delivered about eleven.
        let passages = (0 ..< 2).map { index in
            Self.passage(
                "Dask was a thief. The rain kept on. Dask, who had trained her, waited.",
                spine: 2, ordinal: index, start: 1_000 + index * 5_000,
            )
        }
        let evidence = EvidenceFinder.identity(
            subject: Self.subject("Dask", tokens: ["dask"]), in: passages, limit: 4,
        )
        // Two first mentions and two predicates, all four distinct sentences.
        #expect(evidence.count == 4)
        #expect(evidence.map(\.role) == [.firstMention, .predicate, .firstMention, .predicate])
        #expect(evidence.map(\.priority) == [0, 2, 1, 3])
    }

    @Test("evidence becomes ranked passages one for one, in the order it came")
    func rankedIsOneToOne() {
        func piece(spine: Int, priority: Int) -> Evidence {
            Evidence(
                excerpt: Passage(
                    spineIndex: spine, ordinal: 0, start: 0, end: 40, words: 8,
                    text: "Her brother, Dask, had taught her that.",
                ),
                sentence: NSRange(location: 0, length: 40),
                role: .kinship,
                sentenceText: "Her brother, Dask, had taught her that.",
                priority: priority,
            )
        }
        let evidence = [piece(spine: 2, priority: 1), piece(spine: 5, priority: 0)]
        let ranked = EvidenceFinder.ranked(evidence)

        // The best citation the feature has rests on this: `KinshipExtractor`
        // cites `evidenceIndex + 1` into the array this was built from, so an
        // excerpt dropped or reordered here is an answer pointing at a sentence
        // it was not lifted from.
        #expect(ranked.map(\.passage) == evidence.map(\.excerpt))
        // And the priority comes with it, or the trimming has nothing to go on
        // but position — which is where this whole defect started.
        #expect(ranked.map(\.priority) == [1, 0])
    }

    // MARK: - Kinship

    @Test("the antecedent comes into the window when the kin sentence uses a pronoun")
    func kinshipReachesOneSentenceBack() {
        // The measured failure in one sentence: the book says "Her brother,
        // Dask…" and never repeats her name in that sentence. Without the
        // sentence before it, the evidence does not say whose brother he is.
        let evidence = EvidenceFinder.kinship(
            subject: Self.subject("Ryn", tokens: ["ryn"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage(
                "Ryn had been raised on the streets of Ardmoor. Her brother, Dask, "
                    + "had trained her to trust nobody. The mists came early that year.",
            )],
        )
        let first = try? #require(evidence.first)
        #expect(first?.role == .kinship)
        #expect(first?.sentenceText.contains("Her brother, Dask") == true)
        #expect(first?.excerpt.text.contains("Ryn had been raised") == true)
        #expect(first?.excerpt.text.contains("The mists came early") == false)
    }

    @Test("a kin sentence about somebody else is not evidence")
    func kinshipRequiresTheSubject() {
        let evidence = EvidenceFinder.kinship(
            subject: Self.subject("Ryn", tokens: ["ryn"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage(
                "The soldiers rested by the wall. Marek's brother had gone north years ago. "
                    + "Nobody had heard from him.",
            )],
        )
        #expect(evidence.isEmpty)
    }

    @Test("the relation reaches the whole family group")
    func kinshipReachesTheGroup() {
        // A novel introduces a brother once and then uses his name; the
        // sentence a reader is asking about may say "sibling" and never
        // "brother".
        let evidence = EvidenceFinder.kinship(
            subject: Self.subject("Ryn", tokens: ["ryn"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage("Ryn's only sibling had died in the mines.")],
        )
        #expect(evidence.count == 1)
    }

    // MARK: - Against the real book

    /// Retrieval as the retriever runs it, so the tests are about the sentences
    /// rather than about the query.
    static func evidence(
        for question: String, spine: Int,
    ) async throws -> ([Evidence], AskIndexStore, URL) {
        let (store, _, directory) = try await AskFixture.preparedStore()
        let boundary = try AskFixture.endOf(spine: spine)
        let known = try await store.topNames(in: AskFixture.bookUUID, before: boundary, limit: 200)
        let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)
        let terms = QueryTerms.extract(from: question, knownNames: known)
        return (try await retriever.evidence(for: terms), store, directory)
    }

    @Test("who the White Rabbit is comes back as the sentences that say so")
    func findsTheWhiteRabbit() async throws {
        let (evidence, _, directory) = try await Self.evidence(
            for: "Who is the White Rabbit?", spine: AskFixture.Spine.chapterI,
        )
        defer { AskFixture.remove(directory) }
        try #require(!evidence.isEmpty)
        let text = evidence.map(\.excerpt.text).joined(separator: " ").lowercased()
        // The two things Chapter I actually says about him.
        #expect(text.contains("waistcoat"))
        #expect(text.contains("watch"))
        #expect(text.contains("pink eyes"))
    }

    @Test("an evidence excerpt is still a place in the book")
    func excerptsKeepRealOffsets() async throws {
        let (evidence, _, directory) = try await Self.evidence(
            for: "Who is the Duchess?", spine: AskFixture.Spine.chapterVI,
        )
        defer { AskFixture.remove(directory) }
        try #require(!evidence.isEmpty)

        for piece in evidence {
            // Compared against a *fresh* parse, not against the index's memory
            // of one: the whole spoiler defence is that these offsets and the
            // reader's are measured against the same string.
            let fresh = try AskFixture.text(spine: piece.excerpt.spineIndex) as NSString
            #expect(piece.excerpt.end <= fresh.length)
            #expect(fresh.substring(with: piece.excerpt.range) == piece.excerpt.text)
        }
    }

    @Test("the evidence is bounded, ordered and capped")
    func evidenceIsBoundedAndCapped() async throws {
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)
        let (evidence, _, directory) = try await Self.evidence(
            for: "Who is Alice?", spine: AskFixture.Spine.chapterVI,
        )
        defer { AskFixture.remove(directory) }
        try #require(!evidence.isEmpty)

        #expect(evidence.count <= EvidenceFinder.Limits.identityExcerpts)
        #expect(evidence.allSatisfy { $0.excerpt.spineIndex <= boundary.spineIndex })
        #expect(evidence.allSatisfy {
            $0.excerpt.spineIndex < boundary.spineIndex || $0.excerpt.end <= boundary.charOffset
        })
        let order = evidence.map { ($0.excerpt.spineIndex, $0.excerpt.start) }
        #expect(order.elementsEqual(order.sorted { $0 < $1 }, by: ==))
    }

    @Test("the excerpt limit reaches all four kinds of question")
    func theLimitReachesEveryBranch() async throws {
        // It used to reach one of them. A recap took its own constant of six,
        // identity and kinship ignored the argument outright, and only a
        // general question was answered with the number anybody had tuned — so
        // the count could be raised and three questions in four would not
        // notice. The structure is the fix here; the number is the easy half.
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)
        let known = try await store.topNames(in: AskFixture.bookUUID, before: boundary, limit: 200)
        let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)

        var labels: Set<String> = []
        for question in [
            "What has happened so far?",
            "Who is the Duchess?",
            "Who is Alice's sister?",
            "What did Alice drink to make herself smaller?",
        ] {
            let terms = QueryTerms.extract(from: question, knownNames: known)
            labels.insert(terms.kind.label)
            // Four, which is above `AskRetriever.Limits.kinshipFloor` and below
            // the six every branch used to help itself to.
            let capped = try await retriever.evidence(for: terms, limit: 4)
            #expect(capped.count <= 4, "\(terms.kind.label) took \(capped.count)")
            // And the cap has to be biting, or a branch that ignores it
            // altogether passes the line above by having found very little.
            let generous = try await retriever.evidence(for: terms, limit: 12)
            #expect(generous.count > 4, "\(terms.kind.label) took \(generous.count)")
        }
        // All four branches, or the loop above tested one of them four times.
        #expect(labels == ["recap", "identity", "kinship", "general"])
    }

    @Test("an unnamed relative comes back as the sentence that mentions her")
    func findsTheUnnamedSister() async throws {
        let (evidence, _, directory) = try await Self.evidence(
            for: "Who is Alice's sister?", spine: AskFixture.Spine.chapterI,
        )
        defer { AskFixture.remove(directory) }
        try #require(!evidence.isEmpty)
        let text = evidence.map(\.excerpt.text).joined(separator: " ").lowercased()
        #expect(text.contains("sister"))
        // The book never names her, so nothing here may look like a name for
        // her — this is the case the deterministic extractor must decline.
        #expect(KinshipExtractor.names(
            subject: Self.subject("Alice", tokens: ["alice"]),
            relation: KinRelation.matching("sister"),
            in: evidence,
        ).isEmpty)
    }

    @Test("every question in the fixtures retrieves the sentences it should")
    func fixtureEvidenceIsRight() async throws {
        for (book, questions) in AskQuestionFixture.books() {
            let (store, _, directory) = try await book.preparedStore()
            defer { AskFixture.remove(directory) }

            for fixture in try AskQuestionFixture.all(questions) {
                let boundary = try fixture.boundary(in: book)
                let known = try await store.topNames(
                    in: book.bookUUID, before: boundary, limit: 200,
                )
                let terms = QueryTerms.extract(from: fixture.question, knownNames: known)
                #expect(terms.kind.label == fixture.kind, "\(fixture.question) @ \(fixture.spine)")

                let retriever = AskRetriever(
                    store: store, bookUUID: book.bookUUID, boundary: boundary,
                )
                let evidence = try await retriever.evidence(for: terms)
                let text = evidence.map(\.excerpt.text).joined(separator: "\n").lowercased()
                for needle in fixture.evidenceContains {
                    #expect(text.contains(needle), "\(fixture.name): missing \(needle)")
                }
                for needle in fixture.evidenceExcludes {
                    #expect(!text.contains(needle), "\(fixture.name): leaked \(needle)")
                }
                // Still bounded, whatever the question.
                #expect(evidence.allSatisfy {
                    $0.excerpt.spineIndex < boundary.spineIndex
                        || ($0.excerpt.spineIndex == boundary.spineIndex
                            && $0.excerpt.end <= boundary.charOffset)
                }, "\(fixture.name)")

                guard let expected = fixture.kinshipNames,
                      case let .kinship(subject, relation, _, _) = terms.kind else { continue }
                let names = KinshipExtractor.names(
                    subject: subject, relation: relation, in: evidence,
                    knownNames: Set(known.map { NameFinder.Name.key(for: $0) }),
                )
                #expect(names.count == expected, "\(fixture.name): \(names.map(\.name))")
            }
        }
    }

    // MARK: - Recap

    @Test("a recap reads forwards but gives up its oldest passages first")
    func recapPrioritisesTheMostRecent() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)
        let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)
        let terms = QueryTerms.extract(from: AskSuggestions.recap)
        try #require(terms.isRecap)

        let evidence = try await retriever.evidence(for: terms)
        try #require(evidence.count > 1)
        // Reading order for the model: a recap read backwards is a worse recap.
        let order = evidence.map { ($0.excerpt.spineIndex, $0.excerpt.start) }
        #expect(order.elementsEqual(order.sorted { $0 < $1 }, by: ==))
        // Recency for the trimming. "What has happened so far" is a question
        // about the end of what has happened, so when the prompt will not fit
        // it is the opening that should go — and trimming on position dropped
        // exactly the chapter the reader had just closed.
        #expect(evidence.map(\.priority) == Array((0 ..< evidence.count).reversed()))
        let kept = PassageRanker.best(EvidenceFinder.ranked(evidence), count: 1)
        #expect(kept.first?.passage == evidence.last?.excerpt)
    }

    // MARK: - Ordering and de-duplication

    @Test("two chapters opening the same length apart keep both their sentences")
    func openingSentencesInDifferentChaptersAreNotOneSentence() {
        // A sentence's range is chapter-relative, so a chapter opening at
        // location 0 with a length of 40 looks identical to the next chapter's
        // opening 40 characters — and the set dropped one of them, which on a
        // kinship question could be the only evidence there was.
        func evidence(spine: Int, text: String) -> Evidence {
            Evidence(
                excerpt: Passage(
                    spineIndex: spine, ordinal: 0, start: 0, end: 40, words: 8, text: text,
                ),
                sentence: NSRange(location: 0, length: 40),
                role: .kinship,
                sentenceText: text,
            )
        }
        let kept = EvidenceFinder.inBookOrder([
            evidence(spine: 2, text: "Her brother, Dask, had taught her that."),
            evidence(spine: 5, text: "Her sister, Marek, had taught her too."),
        ])
        #expect(kept.count == 2)
        #expect(kept.map(\.excerpt.spineIndex) == [2, 5])
    }

    @Test("the same sentence in the same chapter is still kept once")
    func oneSentenceIsOneExcerpt() {
        let passage = Passage(
            spineIndex: 2, ordinal: 0, start: 0, end: 40, words: 8,
            text: "Her brother, Dask, had taught her that.",
        )
        let piece = Evidence(
            excerpt: passage, sentence: NSRange(location: 0, length: 40),
            role: .kinship, sentenceText: passage.text,
        )
        // Two overlapping windows are the same text twice, numbered as two
        // excerpts — which spends the budget twice and invites the model to
        // cite one fact as two sources.
        #expect(EvidenceFinder.inBookOrder([piece, piece]).count == 1)
    }

    @Test("the whole scan of a chapter is quick enough to run per question")
    func scanIsFastEnough() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let boundary = try AskFixture.endOf(spine: AskFixture.Spine.chapterVI)
        let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)
        let terms = QueryTerms.extract(from: "Who is Alice?", knownNames: ["Alice"])

        let start = ContinuousClock.now
        for _ in 0 ..< 5 { _ = try await retriever.evidence(for: terms) }
        let each = (ContinuousClock.now - start) / 5
        // Four indexed queries and a bounded scan. Generous by a wide margin:
        // it is here to catch a regex compiled per sentence, not to police
        // milliseconds.
        #expect(each < .milliseconds(250), "\(each)")
    }
}
