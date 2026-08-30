import CoreGraphics

/// Which part of the page a tap landed in.
///
/// The outer quarters turn pages and the middle half shows or hides the chrome,
/// which is what upstream Storyteller and Kindle both do. Split out of the view
/// so the boundaries can be tested: the original test compared an x in the
/// padded frame's space against the canvas width, so the back zone was a margin
/// narrower than intended and shifted inward.
public enum ReaderTapZone: Sendable, Equatable {
    case back
    case middle
    case forward

    /// - Parameters:
    ///   - x: horizontal position in the PADDED frame, which is what a tap
    ///     gesture on the padded canvas reports.
    ///   - pageWidth: the canvas width, inside the margins.
    ///   - margin: the page margin applied on each side.
    public static func of(x: CGFloat, pageWidth: CGFloat, margin: CGFloat) -> ReaderTapZone {
        let full = pageWidth + margin * 2
        guard full > 0 else { return .middle }
        let fraction = x / full
        if fraction < 0.25 { return .back }
        if fraction > 0.75 { return .forward }
        return .middle
    }
}
