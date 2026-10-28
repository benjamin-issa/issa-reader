import CoreGraphics
import Testing

@testable import IssaReader_iOS

/// What a swipe on a download's row does. `HorizontalPan` decides only whether
/// a pan begins sideways; these are the checks made as it goes and when it ends.
@Suite("Swiping a row to remove it")
struct SwipeDecisionTests {
    @Test("a horizontal swipe past the commit distance removes the row")
    func horizontalPastCommitCommits() {
        let outcome = SwipeDecision.outcome(
            translation: CGSize(width: -SwipeDecision.commitDistance - 20, height: 6),
            isOpen: false)
        #expect(outcome == .commit)
    }

    /// The failure this guards: a pan that begins sideways, then scrolls the
    /// screen while drifting left. Past the commit distance on x alone.
    @Test("a mostly vertical drag never removes, however far left it drifts")
    func mostlyVerticalDoesNotCommit() {
        let drift = CGSize(width: -210, height: 250)
        #expect(!SwipeDecision.isHorizontal(drift))
        #expect(SwipeDecision.outcome(translation: drift, isOpen: false) == .ignore)
        #expect(SwipeDecision.outcome(translation: drift, isOpen: true) == .ignore)
    }

    @Test("a diagonal that is exactly even is a scroll")
    func evenDiagonalIsNotHorizontal() {
        #expect(!SwipeDecision.isHorizontal(CGSize(width: -100, height: 100)))
        #expect(SwipeDecision.isHorizontal(CGSize(width: -101, height: 100)))
    }

    @Test("a swipe past half the button leaves the row open")
    func pastHalfRevealWidthReveals() {
        let past = CGSize(width: -SwipeDecision.revealWidth / 2 - 1, height: 0)
        #expect(SwipeDecision.outcome(translation: past, isOpen: false) == .reveal)
        let short = CGSize(width: -SwipeDecision.revealWidth / 2 + 1, height: 0)
        #expect(SwipeDecision.outcome(translation: short, isOpen: false) == .close)
    }

    @Test("an open row counts the button's width it already shows")
    func openRowCountsItsOffset() {
        // 120 left of an open row is 88 + 120 from rest: past the commit.
        let far = CGSize(width: -120, height: 0)
        #expect(SwipeDecision.outcome(translation: far, isOpen: true) == .commit)
        #expect(SwipeDecision.outcome(translation: far, isOpen: false) == .reveal)
        // A swipe right on an open row closes it.
        let back = CGSize(width: 60, height: 0)
        #expect(SwipeDecision.outcome(translation: back, isOpen: true) == .close)
    }
}
