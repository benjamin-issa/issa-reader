import Foundation
import Testing

@testable import IssaCore

/// Refusing a position write that would destroy a reading place.
///
/// The reproduction below is one test. The dozen after it are the ones that
/// matter: a guard that blocks a reader from jumping back to chapter one is a
/// worse bug than the one it prevents, so most of this file exists to prove that
/// legitimate backwards movement is untouched.
@Suite("Guarding a reading position")
struct PositionGuardTests {
    // MARK: - The report, reproduced

    /// Reading at 31% of "The Hero of Ages", narration began at the first
    /// sentence of the audiobook and the app wrote that over the real position.
    @Test("narration that starts at the beginning does not destroy a reading place")
    func refusesTheReportedRegression() {
        var guardState = PositionGuard(highWater: 0.31)
        #expect(guardState.decide(0.0004, origin: .derived) == .refuse(held: 0.31, candidate: 0.0004))
        // The write repeats every couple of seconds; every one must be refused.
        #expect(!guardState.decide(0.0009, origin: .derived).isAllowed)
        #expect(!guardState.decide(0.0016, origin: .derived).isAllowed)
        #expect(guardState.highWater == 0.31, "a refused write must not move the mark")
    }

    // MARK: - Movement the reader asked for, which must never be blocked

    @Test("a reader who jumps back to chapter one from the contents is not stopped")
    func allowsContentsJump() {
        var guardState = PositionGuard(highWater: 0.62)
        #expect(guardState.decide(0.01, origin: .chosen).isAllowed)
    }

    @Test("a bookmark twenty chapters back is not stopped")
    func allowsBookmarkJump() {
        var guardState = PositionGuard(highWater: 0.62)
        #expect(guardState.decide(0.18, origin: .chosen).isAllowed)
    }

    @Test("a search hit behind the reader is not stopped")
    func allowsSearchHitBehind() {
        var guardState = PositionGuard(highWater: 0.44)
        #expect(guardState.decide(0.02, origin: .chosen).isAllowed)
    }

    @Test("scrubbing backwards in the player is not stopped")
    func allowsScrubBack() {
        var guardState = PositionGuard(highWater: 0.62)
        #expect(guardState.decide(0.30, origin: .chosen).isAllowed)
    }

    @Test("restarting a finished book is not stopped")
    func allowsRestart() {
        var guardState = PositionGuard(highWater: 0.99)
        #expect(guardState.decide(0.0, origin: .chosen).isAllowed)
    }

    /// The sequel to restarting, and the most valuable test here: having gone
    /// back to the beginning on purpose, reading *on* from there must work. This
    /// fails against a `highWater = max(highWater, candidate)` implementation on
    /// the `.chosen` branch, which is the obvious wrong way to write it.
    @Test("and reading on from a restart is not stopped either")
    func allowsReadingOnAfterRestart() {
        var guardState = PositionGuard(highWater: 0.99)
        #expect(guardState.decide(0.0, origin: .chosen).isAllowed)
        #expect(guardState.highWater == 0.0, "choosing a place re-baselines to it")
        #expect(guardState.decide(0.004, origin: .derived).isAllowed,
                "narration must be able to carry on from where the reader restarted")
    }

    // MARK: - Small movements, which are ordinary reading

    @Test("flipping back a page is not stopped even when it is unattended")
    func allowsPageFlipBack() {
        var guardState = PositionGuard(highWater: 0.400)
        #expect(guardState.decide(0.399, origin: .derived).isAllowed)
    }

    /// A skip-back from headphones may arrive classified as derived. Thirty
    /// seconds of a normal-length book is far inside the tolerance.
    @Test("a thirty-second skip back is allowed even when it is mislabelled")
    func allowsMislabelledSkipBack() {
        var guardState = PositionGuard(highWater: 0.62, duration: 36_000)
        #expect(guardState.decide(0.6192, origin: .derived).isAllowed)
    }

    @Test("the highlight re-anchoring at a chapter boundary is not stopped")
    func allowsChapterBoundaryReanchor() {
        // One chapter of an eighty-chapter novel is a little over 1%.
        var guardState = PositionGuard(highWater: 0.500)
        #expect(guardState.decide(0.4875, origin: .derived).isAllowed)
    }

    @Test("a forward write is never refused", arguments: [0.001, 0.1, 0.5, 1.0])
    func allowsForwardWrites(_ candidate: Double) {
        for origin in [PositionOrigin.chosen, .derived] {
            var guardState = PositionGuard(highWater: 0.0)
            #expect(guardState.decide(candidate, origin: origin).isAllowed)
        }
    }

    @Test("a book barely started is not guarded")
    func allowsEarlyBook() {
        var guardState = PositionGuard(highWater: 0.01)
        #expect(guardState.decide(0.0, origin: .derived).isAllowed)
    }

    // MARK: - The state machine

    /// The discriminator between a high-water mark and a "compare with the last
    /// write" rule. Against the latter all forty steps pass and the reader ends
    /// up a sixth of the book behind where they were.
    @Test("a run of small steps back cannot walk the position out of the book")
    func refusesCreepingRegression() {
        var guardState = PositionGuard(highWater: 0.62)
        var candidate = 0.62
        var allowed = 0
        for _ in 0 ..< 40 {
            candidate -= 0.004
            if guardState.decide(candidate, origin: .derived).isAllowed { allowed += 1 }
        }
        #expect(allowed < 20, "the mark must not follow the writes downwards")
        #expect(guardState.highWater == 0.62)
    }

    @Test("the high point is what a write is measured against, not the last value")
    func measuresAgainstHighWater() {
        var guardState = PositionGuard(highWater: 0.0)
        #expect(guardState.decide(0.80, origin: .derived).isAllowed)
        #expect(guardState.decide(0.79, origin: .derived).isAllowed)
        #expect(!guardState.decide(0.10, origin: .derived).isAllowed)
    }

    @Test("a non-finite or out-of-range progression is refused whatever its origin",
          arguments: [Double.nan, .infinity, -0.5, 1.5])
    func refusesNonsense(_ candidate: Double) {
        for origin in [PositionOrigin.chosen, .derived] {
            var guardState = PositionGuard(highWater: 0.5)
            #expect(!guardState.decide(candidate, origin: origin).isAllowed)
        }
    }

    @Test("a write carrying no progression is not a claim about position")
    func allowsNilProgression() {
        var guardState = PositionGuard(highWater: 0.5)
        #expect(guardState.decide(nil, origin: .derived).isAllowed)
        #expect(guardState.highWater == 0.5)
    }

    // MARK: - The seconds arm

    @Test("five minutes of a forty-hour audiobook is the whole tolerance")
    func tightensToleranceOnLongBooks() {
        var guardState = PositionGuard(highWater: 0.5, duration: 144_000)
        // 0.002 of the book is ~4.8 minutes: inside.
        #expect(guardState.decide(0.498, origin: .derived).isAllowed)
        // 2% is nearly fifty minutes: far outside, though it would pass the
        // 5% fraction rule on its own.
        var other = PositionGuard(highWater: 0.5, duration: 144_000)
        #expect(!other.decide(0.48, origin: .derived).isAllowed)
    }

    @Test("a short audiobook keeps the five per cent floor")
    func keepsFractionFloorOnShortBooks() {
        var guardState = PositionGuard(highWater: 0.5, duration: 3600)
        #expect(guardState.decide(0.46, origin: .derived).isAllowed)
        #expect(!guardState.decide(0.40, origin: .derived).isAllowed)
    }

    @Test("a book with no narration falls back to the fraction rule")
    func noDurationUsesFraction() {
        let guardState = PositionGuard(highWater: 0.5, duration: nil)
        #expect(guardState.tolerance == PositionGuard.fractionTolerance)
    }
}
