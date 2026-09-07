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
            subject: Self.subject("Reen", tokens: ["reen"]),
            in: [Self.passage(
                "The street was empty. Reen came in from the rain. He was her brother, "
                    + "and had trained her since she could walk. Nobody spoke.",
            )],
        )
        let first = try? #require(evidence.first)
        #expect(first?.role == .firstMention)
        // An introduction is regularly two sentences: the arrival, then who
        // they are.
        #expect(first?.excerpt.text.contains("Reen came in") == true)
        #expect(first?.excerpt.text.contains("her brother") == true)
        #expect(first?.excerpt.text.contains("The street was empty") == false)
    }

    @Test("a sentence that predicates something of the subject is kept")
    func keepsPredicateSentences() {
        let patterns = Patterns(subject: Self.subject("Vin", tokens: ["vin"]))
        for sentence in [
            "vin was a mistborn of great skill.",
            "vin, the heir of the survivor, said nothing.",
            "vin, who had been raised on the streets, waited.",
            "the crew called her vin from then on.",
            "vin is the one they follow.",
        ] {
            #expect(patterns.saysSomethingAbout(sentence), "\(sentence)")
        }
        // A sentence that merely has her in it says nothing about her, and six
        // of those is the biography stitched out of passing mentions.
        #expect(!patterns.saysSomethingAbout("vin ran down the alley and jumped."))
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
        let single = Patterns(subject: Self.subject("Vin", tokens: ["vin"]))
        #expect(!single.mentions("the vine grew over the wall."))
    }

    // MARK: - Kinship

    @Test("the antecedent comes into the window when the kin sentence uses a pronoun")
    func kinshipReachesOneSentenceBack() {
        // The measured failure in one sentence: the book says "Her brother,
        // Reen…" and never repeats her name in that sentence. Without the
        // sentence before it, the evidence does not say whose brother he is.
        let evidence = EvidenceFinder.kinship(
            subject: Self.subject("Vin", tokens: ["vin"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage(
                "Vin had been raised on the streets of Luthadel. Her brother, Reen, "
                    + "had trained her to trust nobody. The mists came early that year.",
            )],
        )
        let first = try? #require(evidence.first)
        #expect(first?.role == .kinship)
        #expect(first?.sentenceText.contains("Her brother, Reen") == true)
        #expect(first?.excerpt.text.contains("Vin had been raised") == true)
        #expect(first?.excerpt.text.contains("The mists came early") == false)
    }

    @Test("a kin sentence about somebody else is not evidence")
    func kinshipRequiresTheSubject() {
        let evidence = EvidenceFinder.kinship(
            subject: Self.subject("Vin", tokens: ["vin"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage(
                "The soldiers rested by the wall. Elend's brother had gone north years ago. "
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
            subject: Self.subject("Vin", tokens: ["vin"]),
            relation: KinRelation.matching("brother"),
            in: [Self.passage("Vin's only sibling had died in the pits.")],
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

    @Test("every question in the fixture retrieves the sentences it should")
    func fixtureEvidenceIsRight() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }

        for fixture in try AskQuestionFixture.all() {
            let boundary = try fixture.boundary
            let known = try await store.topNames(in: AskFixture.bookUUID, before: boundary, limit: 200)
            let terms = QueryTerms.extract(from: fixture.question, knownNames: known)
            #expect(terms.kind.label == fixture.kind, "\(fixture.question) @ \(fixture.spine)")

            let retriever = AskRetriever(store: store, bookUUID: AskFixture.bookUUID, boundary: boundary)
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
