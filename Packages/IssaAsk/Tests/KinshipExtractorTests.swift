import Foundation
import Testing

@testable import IssaAsk

/// The one tokeniser, which is the reason the extractor's comparisons mean
/// anything.
///
/// `KinshipExtractor` asks whether a word of the book's sentence is one of the
/// question's subject tokens. That was two splitting functions differing in one
/// character, so a name written the same way on both sides could tokenise
/// differently and the comparison answered no.
@Suite("Splitting words")
struct WordsTests {
    @Test(
        "a question and a sentence tokenise a name the same way",
        arguments: ["Jean'Luc", "Jean-Luc", "O'Brien", "St.John", "Ryn"],
    )
    func bothSidesAgree(name: String) {
        let asked = QuestionReader.words(in: "Who is \(name)?")
        let printed = Words.split("She met \(name) at the gate.")
        let questionToken = asked.last?.token
        let sentenceToken = printed.dropFirst(2).first?.token
        #expect(
            questionToken == sentenceToken,
            "\(name): \(questionToken ?? "-") against \(sentenceToken ?? "-")",
        )
    }

    @Test("a possessive is stripped the same way on both sides")
    func possessivesAgree() {
        let asked = QuestionReader.words(in: "Who is Ryn's brother?").dropFirst(2).first
        let printed = Words.split("Her brother, Ryn's, arrived.").dropFirst(2).first
        #expect(asked?.isPossessive == true)
        #expect(asked?.token == "ryn")
        #expect(printed?.token == "ryn")
    }

    @Test("who's still becomes two words, so the identity lead-in matches")
    func contractionsStillExpand() {
        #expect(QuestionReader.words(in: "Who's Ryn?").map(\.token) == ["who", "is", "ryn"])
    }
}

/// The one place the app answers without asking the model.
///
/// Every test here is about the extractor declining. Over-reach is a confident
/// wrong answer with a citation on it; under-reach is the model answering with
/// the right sentence still in front of it, which is what used to happen and
/// what "Sorrel" came out of.
struct KinshipExtractorTests {
    static let ryn = Subject(display: "Ryn", tokens: ["ryn"], isKnownName: true)
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
        _ sentence: String, preceding: String? = nil, known: Set<String> = ["ryn", "dask"],
    ) -> [String] {
        KinshipExtractor.names(
            subject: ryn, relation: brother, in: [evidence(sentence, preceding: preceding)],
            knownNames: known,
        ).map(\.name)
    }

    // MARK: - The six shapes

    @Test("the table reads the six ways a book states a relationship")
    func readsEveryPattern() {
        // X's KIN, NAME
        #expect(Self.names("Ryn's brother, Dask, had trained her.") == ["Dask"])
        // NAME, X's KIN
        #expect(Self.names("Dask, Ryn's brother, had trained her.") == ["Dask"])
        // NAME was X's KIN
        #expect(Self.names("Dask was Ryn's brother, and he trained her.") == ["Dask"])
        // X's KIN was called NAME
        #expect(Self.names("Ryn's brother was called Dask.") == ["Dask"])
        // PRON KIN, NAME
        #expect(Self.names("Ryn remembered. Her brother, Dask, had trained her.") == ["Dask"])
        // NAME, PRON KIN
        #expect(Self.names("Ryn waited while Dask, her brother, watched the door.") == ["Dask"])
    }

    @Test("an adjective between the owner and the relation changes nothing")
    func stepsOverAdjectives() {
        #expect(Self.names("Ryn's younger brother, Dask, had trained her.") == ["Dask"])
        #expect(Self.names("Ryn's own elder brother, Dask, waited.") == ["Dask"])
    }

    // MARK: - Reach

    @Test("a pronoun reaches back exactly one sentence, and only when nobody else is there")
    func pronounReachIsOneSentence() {
        // The sentence names her: nothing to resolve.
        #expect(Self.names("Ryn sighed, and her brother, Dask, said nothing.") == ["Dask"])
        // One sentence back, and she is the only person in it.
        #expect(Self.names(
            "Her brother, Dask, had trained her.", preceding: "Ryn had grown up on the streets.",
        ) == ["Dask"])
        // One sentence back, but somebody else is standing in it: "her" is as
        // likely to be Aldric's sister as Ryn.
        #expect(Self.names(
            "Her brother, Dask, had trained her.",
            preceding: "Ryn turned away, and Aldric watched her go.",
        ).isEmpty)
        // Nothing to reach back to at all.
        #expect(Self.names("Her brother, Dask, had trained her.").isEmpty)
    }

    @Test("a relationship somebody else owns is not the subject's")
    func requiresTheSubjectAsOwner() {
        #expect(Self.names("Marek's brother, Dask, had gone north.").isEmpty)
    }

    // MARK: - Declining

    @Test("a negation drops the match rather than reversing it")
    func negationDeclines() {
        // The words the table matches on are all still there; only the meaning
        // has changed, and the table cannot see meaning.
        #expect(Self.names("Dask was not Ryn's brother, whatever she said.").isEmpty)
        #expect(Self.names("Ryn's brother, Dask, was never mentioned again.").isEmpty)
    }

    @Test("two names is the model's problem, not the table's")
    func twoNamesDecline() {
        let evidence = [
            Self.evidence("Ryn's brother, Dask, had trained her."),
            Self.evidence("Ryn's brother, Aldric, disagreed."),
        ]
        let matches = KinshipExtractor.names(
            subject: Self.ryn, relation: Self.brother, in: evidence,
            knownNames: ["ryn", "dask", "aldric"],
        )
        #expect(matches.map(\.name) == ["Dask", "Aldric"])
        // Two brothers, or a pattern that matched something it should not
        // have. Either way the sentences go to the model.
        #expect(KinshipExtractor.answer(
            subject: Self.ryn, relation: Self.brother, form: .whoIs, in: evidence,
            knownNames: ["ryn", "dask", "aldric"],
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
        // "Nobody was Ryn's brother" is not an answer, and neither is any other
        // ordinary word that happens to start a sentence.
        #expect(Self.names("Nobody was Ryn's brother.", known: ["ryn"]).isEmpty)
        // …unless the book has actually used it as a name.
        #expect(Self.names("Dask was Ryn's brother.", known: ["ryn", "dask"]) == ["Dask"])
    }

    @Test("an honorific is not part of the answer")
    func stripsHonorifics() {
        #expect(Self.names("Ryn's brother, Mr. Dask, had trained her.") == ["Dask"])
    }

    // MARK: - How far the finder reaches

    @Test("a second name stated late is still read, and still declines")
    func aSecondNameStatedLateStillDeclines() throws {
        // Twelve kin sentences, not eight, and this is the reason. The ninth
        // to the twelfth is exactly where a book names a *second* brother, and
        // an extractor that stops before it sees one name, answers outright,
        // and cites a sentence the book goes on to contradict. Under-reach
        // sends the question to the model with the right sentence still in
        // front of it; over-reach is the failure this type cannot recover from.
        let sentences = ["Ryn's brother, Dask, had trained her."]
            + Array(repeating: "Ryn glanced at her brother and said nothing.", count: 10)
            + ["Ryn's brother, Marek, had come back that winter."]
        let text = sentences.joined(separator: " ")
        let passage = RetrievedPassage(
            passage: Passage(
                spineIndex: 4, ordinal: 0, start: 0, end: (text as NSString).length,
                words: PassageChunker.wordCount(text), text: text,
            ),
            bm25: -1, isTruncated: false,
        )
        let evidence = EvidenceFinder.kinship(
            subject: Self.ryn, relation: Self.brother, in: [passage],
        )
        // Written against the constant rather than against twelve, so
        // narrowing it fails here and not in a book nobody has run this on.
        try #require(evidence.count == EvidenceFinder.Limits.kinshipSentences)

        let known: Set<String> = ["ryn", "dask", "marek"]
        let matches = KinshipExtractor.names(
            subject: Self.ryn, relation: Self.brother, in: evidence, knownNames: known,
        )
        #expect(matches.map(\.name) == ["Dask", "Marek"])
        #expect(matches.map(\.evidenceIndex) == [0, 11])
        // Two brothers is the book's problem, not the table's: the model gets
        // the sentences with both names in front of it.
        #expect(KinshipExtractor.answer(
            subject: Self.ryn, relation: Self.brother, form: .whoIs, in: evidence,
            knownNames: known,
        ) == nil)
    }

    // MARK: - The answer

    @Test("one name is answered outright, with a citation")
    func answersOneName() throws {
        let answer = try #require(KinshipExtractor.answer(
            subject: Self.ryn, relation: Self.brother, form: .whoIs,
            in: [
                Self.evidence("The mists came early."),
                Self.evidence("Ryn's brother, Dask, had trained her."),
            ],
            knownNames: ["ryn", "dask"],
        ))
        #expect(answer.text == "Ryn's brother is Dask.")
        // One-based, the way the prompt numbers its excerpts.
        #expect(answer.citations == [2])
        #expect(!answer.notYetRevealed)
    }

    @Test("only a who-is question is answered without the model")
    func onlyWhoIsIsAnswered() {
        let evidence = [Self.evidence("Ryn's brother, Dask, had trained her.")]
        for form in [QuestionKind.KinshipForm.yesNo, .howRelated] {
            // "Is Dask Ryn's brother?" wants yes or no, and "Ryn's brother is
            // Dask." answers a question nobody asked.
            #expect(KinshipExtractor.answer(
                subject: Self.ryn, relation: Self.brother, form: form, in: evidence,
                knownNames: ["ryn", "dask"],
            ) == nil, "\(form)")
        }
        #expect(KinshipExtractor.answer(
            subject: Self.ryn, relation: nil, form: .whoIs, in: evidence,
            knownNames: ["ryn", "dask"],
        ) == nil)
    }
}
