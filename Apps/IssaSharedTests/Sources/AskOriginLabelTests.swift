import IssaAsk
import Testing

@testable import IssaReader_iOS

/// What the sheet is allowed to claim about who wrote an answer.
///
/// The pill said "Generated on device · Apple Intelligence" under every
/// answered state, and only one of the three has a model behind it. The other
/// two are `AskAnswerParser.notYetSentinel` — a constant in this repo, emitted
/// with no model call and also substituted over a generated answer by the
/// vetting pass — and `KinshipExtractor`'s sentence, which is a name read
/// straight out of a paragraph the reader has already passed. The suite is here
/// because the pill itself is a SwiftUI `View` this bundle cannot reach.
@Suite("What the answer discloses about itself")
struct AskOriginLabelTests {
    @Test("a model's answer says a model wrote it, on this machine")
    func modelDiscloses() throws {
        let label = try #require(AskOriginLabel.forState(.answered(.model)))
        #expect(label.phrase == "Generated on device · Apple Intelligence")
        #expect(label.glyph == "sparkles")
    }

    /// The finding. A hardcoded refusal is not generated prose, and a
    /// disclosure under it is a claim about text no machine composed.
    @Test("a withheld answer discloses nothing, because nothing was written")
    func withheldDisclosesNothing() {
        #expect(AskOriginLabel.forState(.answered(.withheld)) == nil)
    }

    /// Quieter, not absent: it is the strongest answer the feature gives — the
    /// only one whose citation is provably the sentence it came from — and
    /// saying so is worth more to a reader than an AI disclosure.
    @Test("the book's own sentence says it came from the book")
    func bookGetsItsOwnLabel() throws {
        let label = try #require(AskOriginLabel.forState(.answered(.book)))
        #expect(label.phrase == "From the book")
        #expect(!label.phrase.contains("Apple Intelligence"))
        #expect(label.glyph != "sparkles")
    }

    /// The pill used to appear only once an answer existed, so nothing said
    /// "on device" while the reader was deciding whether to type at all —
    /// which is the moment the fact could still change their mind.
    @Test("a blank field still says where the answer will come from")
    func composingDiscloses() throws {
        let label = try #require(AskOriginLabel.forState(.unanswered))
        #expect(label.phrase.contains("Apple Intelligence"))
        #expect(label.glyph == "sparkles")
    }

    /// The wording has to differ, because the claim does. "Generated" is a
    /// statement about words on screen, and before a question is asked there
    /// are none — a pill claiming a model had written the empty space above it
    /// is the same defect as the one over the refusal.
    @Test("nothing is claimed to have been written until something has been")
    func composingClaimsNothingWasWritten() throws {
        let composing = try #require(AskOriginLabel.forState(.unanswered))
        let answered = try #require(AskOriginLabel.forState(.answered(.model)))
        #expect(composing.phrase != answered.phrase)
        #expect(!composing.phrase.lowercased().contains("generated"))
        #expect(!composing.spoken.lowercased().contains("generated"))
        // …and it still says the thing the reader is being told: on device.
        #expect(composing.phrase.lowercased().contains("on device"))
    }

    @Test("every label a reader can see is also one VoiceOver can read")
    func everyLabelIsSpoken() {
        for state in [AskOriginState.unanswered, .answered(.model), .answered(.book)] {
            guard let label = AskOriginLabel.forState(state) else {
                Issue.record("\(state) should be disclosed")
                continue
            }
            // Not the phrase itself: the middle dot is punctuation VoiceOver has
            // no good reading of, and the glyph would be read separately.
            #expect(!label.spoken.isEmpty)
            #expect(!label.spoken.contains("·"))
        }
    }
}
