import Foundation
import Testing

@testable import IssaCore

/// One quantity, one formatter.
///
/// The bug: the reader's footer and the widget rounded while the book screen and
/// the Continue card truncated, so a book at 13.7% read 14% in one place and 13%
/// in the other — always exactly one apart, and never closing, because it was
/// never staleness.
@Suite("Saying how far through a book you are")
struct ReadingProgressTests {
    /// The reported case, and the whole band it covers.
    @Test("the half-percent band reads the same everywhere it is shown")
    func roundsRatherThanTruncates() {
        #expect(ReadingProgress.percent(0.135) == 14)
        #expect(ReadingProgress.percent(0.137) == 14)
        #expect(ReadingProgress.percent(0.1399) == 14)
        // And below the half, it still rounds down.
        #expect(ReadingProgress.percent(0.134) == 13)
    }

    /// Truncating meant a book sat at 99% through the whole of its last page,
    /// beside a progress ring that had visibly closed.
    @Test("a book that is all but finished reads 100")
    func nearlyDoneRoundsUp() {
        #expect(ReadingProgress.percent(0.996) == 100)
        #expect(ReadingProgress.percent(1.0) == 100)
    }

    @Test("an unstarted book reads zero, not one")
    func unstartedIsZero() {
        #expect(ReadingProgress.percent(0) == 0)
        #expect(ReadingProgress.percent(0.004) == 0)
    }

    /// The book clock has produced NaN before, and it survived every clamp
    /// because Swift's min/max pass it through.
    @Test("a broken clock reads zero rather than crashing")
    func nonFiniteIsZero() {
        #expect(ReadingProgress.percent(.nan) == 0)
        #expect(ReadingProgress.percent(.infinity) == 0)
    }

    @Test("a value outside 0...1 is clamped, not wrapped")
    func clampsOutOfRange() {
        #expect(ReadingProgress.percent(1.4) == 100)
        #expect(ReadingProgress.percent(-0.2) == 0)
    }

    @Test("the label is the number with a percent sign")
    func labelMatchesTheNumber() {
        #expect(ReadingProgress.percentText(0.137) == "14%")
        #expect(ReadingProgress.percentText(0) == "0%")
    }

    /// The point of the type: the widget's own percent must agree with what the
    /// book screen and the reader would show for the same book.
    @Test("the widget snapshot agrees with every other surface")
    func snapshotAgrees() {
        let snapshot = CurrentBookSnapshot(
            bookID: "u", title: "T", author: "A", progress: 0.137)
        #expect(snapshot.percent == ReadingProgress.percent(0.137))
        #expect(snapshot.percent == 14)
    }
}
