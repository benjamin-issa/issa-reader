import CoreGraphics

/// Which part of the page a tap landed in.
///
/// The outer strips turn pages and the rest shows or hides the chrome, which is
/// what upstream Storyteller and Kindle both do. Split out of the view so the
/// boundaries can be tested: the original test compared an x in the padded
/// frame's space against the canvas width, so the back zone was a margin
/// narrower than intended and shifted inward.
public enum ReaderTapZone: Sendable, Equatable {
    case back
    case middle
    case forward

    /// How far a page-turn strip reaches past the margin, in points.
    ///
    /// A turn zone wants to sit over whitespace, so it is sized from the margin
    /// rather than the page: one margin, plus a finger. Measured in points
    /// because a finger is the same size on every device — a plain quarter of
    /// the width put 74pt of live text under "go back" on an iPhone and 232pt
    /// of it on an iPad, which is what makes a reader aiming at a sentence turn
    /// the page by accident.
    static let reachPastMargin: CGFloat = 44

    /// - Parameters:
    ///   - x: horizontal position in the PADDED frame, which is what a tap
    ///     gesture on the padded canvas reports.
    ///   - pageWidth: the canvas width, inside the margins.
    ///   - margin: the page margin applied on each side.
    public static func of(x: CGFloat, pageWidth: CGFloat, margin: CGFloat) -> ReaderTapZone {
        let full = pageWidth + margin * 2
        guard full > 0 else { return .middle }
        // Still capped as a fraction, so the two strips can never crowd out the
        // middle on a narrow page — a split view, or a Slide Over.
        let strip = min(margin + reachPastMargin, full * 0.25)
        if x < strip { return .back }
        if x > full - strip { return .forward }
        return .middle
    }
}
