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
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, Metrics.spacing4 / 2)
            .background(Palette.tangerine.opacity(0.15), in: Capsule())
            // One word, and VoiceOver would otherwise spell it out letter by
            // letter after `textCase(.uppercase)`.
            .accessibilityLabel("Beta")
    }
}
#endif
