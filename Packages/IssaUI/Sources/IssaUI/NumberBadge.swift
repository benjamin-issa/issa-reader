import SwiftUI

/// A small number drawn on artwork: which book in a series a cover is, how
/// many books a series tile holds.
///
/// One recipe rather than two, because the two marks answer the same question
/// in the same place — a numeral over a corner of a cover — and a badge that
/// is bold and slate on one screen and something else on the next reads as two
/// different things. Its own ground for the reason the format mark has one: a
/// cover is arbitrary artwork, and bare white digits vanish on a pale one.
///
/// Monospaced, so a rail of covers numbered 1, 3, 4 has its badges the same
/// width rather than shuffling as the digits change. The caption ramp carries
/// the size, which is how the television gets legible digits without a stated
/// number here — unlike `FormatMarkSize`, whose glyph is a system size and so
/// never goes through the ramp at all.
public struct NumberBadge: View {
    private let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(Typography.caption.weight(.bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, Metrics.spacing8)
            .padding(.vertical, 2)
            .background(Palette.slate, in: Capsule())
    }
}
