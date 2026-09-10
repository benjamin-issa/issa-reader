import Foundation
import IssaAsk
import Testing

@testable import IssaReader_iOS

/// Which excerpt the sources row opens by itself, and what it does when the
/// reader disagrees.
///
/// Two faults, both from one ambiguous sentinel. The state was an `Int?` where
/// nil meant *both* "never opened" and "the reader closed it", so the
/// `onAppear` guard that promised to leave a closed card closed reopened it
/// every time the sheet came back. And `onAppear` fires once per view rather
/// than once per answer, so a second answer rendered into the same row kept the
/// first answer's ordinal.
@Suite("Opening the excerpt under an answer")
struct AskSourcesOpeningTests {
    static func sources(_ ordinals: [Int], from spine: Int = 2) -> [AskSource] {
        ordinals.map { ordinal in
            AskSource(ordinal: ordinal, passage: Passage(
                spineIndex: spine, ordinal: ordinal, start: ordinal * 100,
                end: ordinal * 100 + 50, words: 10,
                text: "excerpt \(ordinal) of spine \(spine)",
            ))
        }
    }

    /// The reason the row exists: the extra sentence comes from the book, and
    /// nobody was tapping to get it.
    @Test("an answer nobody has touched shows its first excerpt")
    func firstIsOpenByDefault() {
        let sources = Self.sources([1, 2, 3])
        #expect(AskSourcesOpening.ordinal(.untouched, in: sources) == 1)
        // Citations are not promised to start at 1 or to be contiguous — the
        // model cites what it used.
        #expect(AskSourcesOpening.ordinal(.untouched, in: Self.sources([2, 5])) == 2)
        #expect(AskSourcesOpening.ordinal(.untouched, in: []) == nil)
    }

    /// The bug the old comment claimed to have fixed and could not, because a
    /// closed card and an untouched one were the same value.
    @Test("a card the reader closed stays closed")
    func closedStaysClosed() {
        let sources = Self.sources([1, 2, 3])
        let afterClosing = AskSourcesOpening.tapping(1, from: .untouched, in: sources)
        #expect(afterClosing == .closed)
        #expect(AskSourcesOpening.ordinal(afterClosing, in: sources) == nil)
        // Which is the part `Int?` could not express: closing must not land
        // back on the state that opens the first card again.
        #expect(afterClosing != .untouched)
    }

    @Test("tapping a different chip moves the card rather than closing it")
    func tappingAnother() {
        let sources = Self.sources([1, 2, 3])
        let opened = AskSourcesOpening.tapping(3, from: .untouched, in: sources)
        #expect(opened == .source(3))
        #expect(AskSourcesOpening.ordinal(opened, in: sources) == 3)
        #expect(AskSourcesOpening.tapping(3, from: opened, in: sources) == .closed)
        // And a closed row opens the one that was tapped, not the first one.
        #expect(AskSourcesOpening.tapping(2, from: .closed, in: sources) == .source(2))
    }

    /// The second half of the defect: the row is reused for the next answer, so
    /// the state has to be reset by the answer changing rather than by the view
    /// appearing. Here that reset is `.untouched`, and this pins what it means.
    @Test("a new answer opens its own first excerpt, not the last answer's ordinal")
    func aNewAnswerStartsAgain() {
        let first = Self.sources([1, 2, 3], from: 2)
        let second = Self.sources([1, 2, 3], from: 9)
        let reader = AskSourcesOpening.tapping(3, from: .untouched, in: first)
        #expect(AskSourcesOpening.ordinal(reader, in: first) == 3)
        // After the reset the new answer behaves as an untouched one.
        #expect(AskSourcesOpening.ordinal(.untouched, in: second) == 1)
    }

    /// Belt and braces for the same thing: even without a reset, an ordinal the
    /// answer on screen does not have reads as nothing open rather than as a
    /// card that cannot be found.
    @Test("an ordinal this answer does not have opens nothing")
    func staleOrdinalOpensNothing() {
        #expect(AskSourcesOpening.ordinal(.source(7), in: Self.sources([1, 2, 3])) == nil)
        #expect(AskSourcesOpening.ordinal(.source(2), in: Self.sources([1, 2, 3])) == 2)
        // And tapping the chip it belongs to still opens it, rather than
        // reading as "already open" and closing.
        #expect(AskSourcesOpening.tapping(2, from: .source(7), in: Self.sources([1, 2, 3]))
            == .source(2))
    }
}
