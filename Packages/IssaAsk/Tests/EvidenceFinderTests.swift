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
}
