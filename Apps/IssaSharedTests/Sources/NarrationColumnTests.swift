import Foundation
import Testing

@testable import IssaReader_iOS

/// What the read-along column may show before it has to give something up.
///
/// The bug these exist for: on a television the sentences arrived truncated
/// mid-word — "and a second later Capt…" — because a bare `VStack` whose
/// children want more height than the parent offers does not overflow, it
/// compresses them, and a `Text` compressed to its minimum is one line with an
/// ellipsis. The fix gives the column somewhere to give: it drops *context*
/// rather than clipping *words*. These assert the two numbers that decision
/// turns on.
@Suite("The read-along column")
struct NarrationColumnTests {
    private static func line(_ id: String, current: Bool = false) -> ReaderModel.NarratedLine {
        ReaderModel.NarratedLine(id: id, text: "sentence \(id)", isCurrent: current)
    }

    /// Seven sentences with the spoken one in the middle — the shape the
    /// television had when it truncated.
    private static let sevenCentred: [ReaderModel.NarratedLine] = [
        line("0"), line("1"), line("2"), line("3", current: true), line("4"), line("5"), line("6"),
    ]

    @Test("the spoken line may run longer than its neighbours")
    func spokenLineGetsMoreRoom() {
        let spoken = NarrationColumn.lineAllowance(isCurrent: true)
        let neighbour = NarrationColumn.lineAllowance(isCurrent: false)
        // Both must exceed one, or the column is back to the bug: one line is
        // exactly what a squeezed `Text` collapses to before it truncates.
        #expect(neighbour > 1)
        #expect(spoken > neighbour)
    }

    @Test(
        "the window narrows around the spoken line",
        arguments: [(2, 5), (1, 3), (0, 1)])
    func trimsToNeighboursEitherSide(neighbours: Int, expected: Int) {
        let trimmed = NarrationColumn.trimmed(Self.sevenCentred, neighbours: neighbours)
        #expect(trimmed.count == expected)
        // The point of narrowing is to keep the sentence being spoken. Losing
        // it would be worse than the truncation this replaces.
        #expect(trimmed.contains { $0.isCurrent })
    }

    @Test("narrowing keeps the spoken line centred")
    func spokenLineStaysCentred() {
        let trimmed = NarrationColumn.trimmed(Self.sevenCentred, neighbours: 1)
        #expect(trimmed.map(\.id) == ["2", "3", "4"])
    }

    /// A sentence at the very start of a chapter has nothing above it.
    @Test("a window at the start of the book clamps rather than trapping")
    func clampsAtTheStart() {
        let lines = [Self.line("0", current: true), Self.line("1"), Self.line("2")]
        let trimmed = NarrationColumn.trimmed(lines, neighbours: 2)
        #expect(trimmed.map(\.id) == ["0", "1", "2"])
    }

    @Test("a window at the end of the book clamps rather than trapping")
    func clampsAtTheEnd() {
        let lines = [Self.line("0"), Self.line("1"), Self.line("2", current: true)]
        let trimmed = NarrationColumn.trimmed(lines, neighbours: 2)
        #expect(trimmed.map(\.id) == ["0", "1", "2"])
    }

    /// Both of these would empty the column, which reads as a broken screen
    /// rather than as a pause — so both hand back what they were given.
    @Test("a window with no spoken line is left alone")
    func noCurrentLineIsLeftAlone() {
        let lines = [Self.line("0"), Self.line("1")]
        #expect(NarrationColumn.trimmed(lines, neighbours: 1).count == 2)
    }

    @Test("an empty window stays empty")
    func emptyStaysEmpty() {
        #expect(NarrationColumn.trimmed([], neighbours: 2).isEmpty)
    }
}
