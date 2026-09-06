import Foundation
import Testing

@testable import IssaAsk

/// The one place the app answers without asking the model.
///
/// Every test here is about the extractor declining. Over-reach is a confident
/// wrong answer with a citation on it; under-reach is the model answering with
/// the right sentence still in front of it, which is what used to happen and
/// what "Quellion" came out of.
struct KinshipExtractorTests {
    static let vin = Subject(display: "Vin", tokens: ["vin"], isKnownName: true)
    static let brother = KinRelation.matching("brother")

    /// One sentence, as `EvidenceFinder` would have handed it over.
    static func evidence(_ sentence: String, preceding: String? = nil) -> Evidence {
        Evidence(
            excerpt: Passage(
                spineIndex: 4, ordinal: 1, start: 0, end: (sentence as NSString).length,
                words: PassageChunker.wordCount(sentence), text: sentence,
            ),
            sentence: NSRange(location: 0, length: (sentence as NSString).length),
            role: .kinship,
            sentenceText: sentence,
            precedingText: preceding,
        )
    }

    static func names(
        _ sentence: String, preceding: String? = nil, known: Set<String> = ["vin", "reen"],
    ) -> [String] {
        KinshipExtractor.names(
            subject: vin, relation: brother, in: [evidence(sentence, preceding: preceding)],
            knownNames: known,
        ).map(\.name)
    }

    // MARK: - The six shapes

    @Test("the table reads the six ways a book states a relationship")
    func readsEveryPattern() {
        // X's KIN, NAME
        #expect(Self.names("Vin's brother, Reen, had trained her.") == ["Reen"])
        // NAME, X's KIN
        #expect(Self.names("Reen, Vin's brother, had trained her.") == ["Reen"])
        // NAME was X's KIN
        #expect(Self.names("Reen was Vin's brother, and he trained her.") == ["Reen"])
        // X's KIN was called NAME
        #expect(Self.names("Vin's brother was called Reen.") == ["Reen"])
        // PRON KIN, NAME
        #expect(Self.names("Vin remembered. Her brother, Reen, had trained her.") == ["Reen"])
        // NAME, PRON KIN
        #expect(Self.names("Vin waited while Reen, her brother, watched the door.") == ["Reen"])
    }

    @Test("an adjective between the owner and the relation changes nothing")
    func stepsOverAdjectives() {
        #expect(Self.names("Vin's younger brother, Reen, had trained her.") == ["Reen"])
        #expect(Self.names("Vin's own elder brother, Reen, waited.") == ["Reen"])
    }

    // MARK: - Reach

    @Test("a pronoun reaches back exactly one sentence, and only when nobody else is there")
    func pronounReachIsOneSentence() {
        // The sentence names her: nothing to resolve.
        #expect(Self.names("Vin sighed, and her brother, Reen, said nothing.") == ["Reen"])
        // One sentence back, and she is the only person in it.
        #expect(Self.names(
            "Her brother, Reen, had trained her.", preceding: "Vin had grown up on the streets.",
        ) == ["Reen"])
        // One sentence back, but somebody else is standing in it: "her" is as
        // likely to be Kelsier's sister as Vin.
        #expect(Self.names(
            "Her brother, Reen, had trained her.",
            preceding: "Vin turned away, and Kelsier watched her go.",
        ).isEmpty)
        // Nothing to reach back to at all.
        #expect(Self.names("Her brother, Reen, had trained her.").isEmpty)
    }

    @Test("a relationship somebody else owns is not the subject's")
    func requiresTheSubjectAsOwner() {
        #expect(Self.names("Elend's brother, Reen, had gone north.").isEmpty)
    }

    // MARK: - Declining

    @Test("a negation drops the match rather than reversing it")
    func negationDeclines() {
        // The words the table matches on are all still there; only the meaning
        // has changed, and the table cannot see meaning.
        #expect(Self.names("Reen was not Vin's brother, whatever she said.").isEmpty)
        #expect(Self.names("Vin's brother, Reen, was never mentioned again.").isEmpty)
    }

    @Test("two names is the model's problem, not the table's")
    func twoNamesDecline() {
        let evidence = [
            Self.evidence("Vin's brother, Reen, had trained her."),
            Self.evidence("Vin's brother, Kelsier, disagreed."),
        ]
        let matches = KinshipExtractor.names(
            subject: Self.vin, relation: Self.brother, in: evidence,
            knownNames: ["vin", "reen", "kelsier"],
        )
        #expect(matches.map(\.name) == ["Reen", "Kelsier"])
        // Two brothers, or a pattern that matched something it should not
        // have. Either way the sentences go to the model.
        #expect(KinshipExtractor.answer(
            subject: Self.vin, relation: Self.brother, form: .whoIs, in: evidence,
            knownNames: ["vin", "reen", "kelsier"],
        ) == nil)
    }

    @Test("an unnamed relative produces no name at all")
    func unnamedRelativesDecline() {
        // Alice's sister is never named in the whole book, and this is the
        // shape of the sentence that mentions her.
        let alice = Subject(display: "Alice", tokens: ["alice"], isKnownName: true)
        let matches = KinshipExtractor.names(
            subject: alice, relation: KinRelation.matching("sister"),
            in: [Self.evidence("Alice was tired of sitting by her sister on the bank.")],
            knownNames: ["alice"],
        )
        #expect(matches.isEmpty)
    }

    @Test("a capital that only opens a sentence is not a name")
    func sentenceOpenersNeedTheBook() {
        // "Nobody was Vin's brother" is not an answer, and neither is any other
        // ordinary word that happens to start a sentence.
        #expect(Self.names("Nobody was Vin's brother.", known: ["vin"]).isEmpty)
        // …unless the book has actually used it as a name.
        #expect(Self.names("Reen was Vin's brother.", known: ["vin", "reen"]) == ["Reen"])
    }

    @Test("an honorific is not part of the answer")
    func stripsHonorifics() {
        #expect(Self.names("Vin's brother, Mr. Reen, had trained her.") == ["Reen"])
    }

    // MARK: - The answer

    @Test("one name is answered outright, with a citation")
    func answersOneName() throws {
        let answer = try #require(KinshipExtractor.answer(
            subject: Self.vin, relation: Self.brother, form: .whoIs,
            in: [
                Self.evidence("The mists came early."),
                Self.evidence("Vin's brother, Reen, had trained her."),
            ],
            knownNames: ["vin", "reen"],
        ))
        #expect(answer.text == "Vin's brother is Reen.")
        // One-based, the way the prompt numbers its excerpts.
        #expect(answer.citations == [2])
        #expect(!answer.notYetRevealed)
    }

    @Test("only a who-is question is answered without the model")
    func onlyWhoIsIsAnswered() {
        let evidence = [Self.evidence("Vin's brother, Reen, had trained her.")]
        for form in [QuestionKind.KinshipForm.yesNo, .howRelated] {
            // "Is Reen Vin's brother?" wants yes or no, and "Vin's brother is
            // Reen." answers a question nobody asked.
            #expect(KinshipExtractor.answer(
                subject: Self.vin, relation: Self.brother, form: form, in: evidence,
                knownNames: ["vin", "reen"],
            ) == nil, "\(form)")
        }
        #expect(KinshipExtractor.answer(
            subject: Self.vin, relation: nil, form: .whoIs, in: evidence,
            knownNames: ["vin", "reen"],
        ) == nil)
    }
}
