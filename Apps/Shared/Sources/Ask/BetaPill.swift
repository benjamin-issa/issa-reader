#if !os(tvOS)
import IssaUI
import SwiftUI

/// The small "BETA" capsule beside anything the Ask feature titles.
///
/// It is on the settings header and on the sheet's own title rather than in one
/// place, because the two are read at different moments: the first when
/// deciding whether to turn it on, the second when an answer turns out to be
/// wrong. The claim being hedged — that a 3B model on a phone can be relied on
/// — is the same both times.
struct BetaPill: View {
    var body: some View {
        Text("Beta")
            .overlineStyle(Palette.tangerine)
            .askPill(Palette.tangerine.opacity(0.15))
            // One word, and VoiceOver would otherwise spell it out letter by
            // letter after `textCase(.uppercase)`.
            .accessibilityLabel("Beta")
    }
}

// MARK: -

extension View {
    /// The capsule both of the Ask sheet's pills are cut from.
    ///
    /// One recipe rather than two that happened to agree. `AskOriginPill` wrote
    /// out the same two padding numbers again, and the same numbers do not give
    /// the same *shape*: "BETA" is four uppercase letters with no descenders,
    /// and the origin pill is a sentence with three of them, so two points of
    /// vertical padding framed the one and pinched the other. Side by side in
    /// the header and the footer of the same sheet, the origin pill read as
    /// visibly the tighter of the two — which is the thing this fixes.
    ///
    /// The vertical padding is `spacing4` rather than half of it, so a
    /// descender has somewhere to go. Both pills grow by the same two points,
    /// which is what keeps them one family rather than two sizes.
    ///
    /// Only the padding and the corner are shared. The fill is not: `BetaPill`
    /// is tinted because it is a warning, and `AskOriginPill` is neutral
    /// because it is a caption that must never compete with the answer above
    /// it — see that file.
    func askPill(_ background: some ShapeStyle) -> some View {
        padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, Metrics.spacing4)
            .background(background, in: Capsule())
    }
}
#endif
