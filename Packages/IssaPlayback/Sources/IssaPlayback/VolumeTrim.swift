import Foundation

/// How far one book's level may depart from the level it was recorded at.
///
/// Self-hosted libraries are assembled from whatever the reader could find, so
/// one book is mastered six decibels under the next and the listener rides the
/// hardware volume between them. This is the per-book correction: a number of
/// decibels either side of "as recorded", stated once so the slider, the Mac's
/// ⌘⌥↑/↓ and the stored preference cannot disagree about what is legal — the
/// same defect `PlaybackRate` exists to close for speed.
///
/// **Decibels, and that is the whole fix.** This shipped as a percentage of the
/// recorded level, and the percentage was lying twice over. −50% is −6.02 dB
/// while +50% is only +3.52 dB, so two thirds of a 9.5 dB slider sat on the
/// quiet side; and because the scale is linear the detents shrink as they climb
/// — −50 → −45% is 0.83 dB, +45 → +50% is 0.29 dB, and a +145 → +150% would
/// have been 0.18 dB. The just-noticeable difference on speech is about 1 dB,
/// so **every detent on the upper half of the old slider was below audibility**,
/// which is exactly what a reader reported: a difference they could hear
/// between the two ends and "pretty much" nowhere else. Extending the
/// percentage to +150% would have added twenty more clicks that provably do
/// nothing.
///
/// A ladder in decibels has none of that. Seventeen rungs from −8 to +8 in
/// steps of one, so every click is one just-noticeable difference wide,
/// wherever on the slider it is. The top rung is 2.512×, which is the 150%
/// louder that was asked for, hit almost exactly — and honestly, because a
/// label that says +8 dB is a claim about loudness rather than about a
/// multiplier the ear does not perceive linearly.
///
/// Upwards it costs headroom: a book already mastered near full scale would
/// clip, which `GainTap` limits with a soft knee rather than wrapping. That is
/// a trade the reader makes deliberately, one detent at a time, hearing each
/// one.
public enum VolumeTrim {
    /// The legal levels, in decibels either side of the recorded one.
    public static let range: ClosedRange<Int> = -8 ... 8
    /// The detent spacing. One decibel is about the smallest change audible on
    /// speech, so a finer slider would only offer values that feel like nothing
    /// happened — which is precisely what the percentage scale offered.
    public static let step = 1
    /// The rungs themselves, named the way `PlaybackRate` names its own so a
    /// caller walking the offered levels does not rederive them from the range.
    public static let ladder: [Int] = Array(
        stride(from: range.lowerBound, through: range.upperBound, by: step))
    /// The multipliers `range` maps onto — 0.398 to 2.512 — named so a caller
    /// clamping a raw float does not have to rederive them. Read off `gain` so
    /// the two cannot drift apart by a rounding.
    public static let gainRange: ClosedRange<Float> = gain(range.lowerBound) ... gain(range.upperBound)

    /// The nearest legal level.
    ///
    /// Snapped before it is clamped, because both ends have to hold: a slider
    /// with a `step` still hands back the odd unsnapped value while a drag is in
    /// flight, and a nudge or a restored preference can arrive from outside the
    /// range entirely.
    public static func clamped(_ decibels: Int) -> Int {
        let snapped = Int((Double(decibels) / Double(step)).rounded()) * step
        return Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
    }

    /// The multiplier a level stands for: 0 → 1, +8 → 2.512, −8 → 0.398.
    ///
    /// Exactly 1 at zero — `powf(10, 0)` is, to the bit — which is what lets the
    /// tap short-circuit an untrimmed book to no work at all.
    public static func gain(_ decibels: Int) -> Float {
        powf(10, Float(clamped(decibels)) / 20)
    }

    /// The nearest legal multiplier.
    ///
    /// Non-finite input is answered with 1 rather than with a bound: a NaN gain
    /// reaching the tap would multiply every sample into silence-or-noise with
    /// nothing on screen to explain it, and "as recorded" is the only honest
    /// reading of a number that is not a number.
    public static func clampedGain(_ gain: Float) -> Float {
        guard gain.isFinite else { return 1 }
        return Swift.min(Swift.max(gain, gainRange.lowerBound), gainRange.upperBound)
    }

    /// The rung a level stored by a build that stored percentages stands for.
    ///
    /// Builds up to 1.1.0 (32) wrote a percentage of the recorded level. The
    /// levels have to keep meaning what they meant — a reader who set a book to
    /// −30% and never touched it again should hear the same book — so the
    /// percentage is converted through the multiplier it always stood for
    /// rather than reinterpreted as a number of decibels.
    ///
    /// Rounding to the nearest rung moves the level a little, and the arithmetic
    /// says how much: over every value a shipped build could hold, the worst
    /// shift is **0.4988 dB, at −25%** — half a just-noticeable difference, so
    /// nobody can hear the migration happen.
    ///
    /// A percentage at or under −100 would be silence or a phase inversion, and
    /// neither is a level any control offered; it reads as the bottom rung.
    public static func decibels(forLegacyPercent percent: Int) -> Int {
        let multiplier = 1 + Double(percent) / 100
        guard multiplier > 0 else { return range.lowerBound }
        return clamped(Int((20 * log10(multiplier)).rounded()))
    }

    /// What the row shows on the right: "As recorded", "+3 dB" or "−6 dB".
    ///
    /// U+2212 MINUS SIGN, not a hyphen: the value is set in a monospaced-digit
    /// face beside a "+" of the same width, and a hyphen is visibly shorter and
    /// sits lower than the plus it alternates with.
    public static func label(_ decibels: Int) -> String {
        let legal = clamped(decibels)
        if legal == 0 { return "As recorded" }
        return legal > 0 ? "+\(legal) dB" : "\u{2212}\(-legal) dB"
    }

    /// What VoiceOver says instead. "+3 dB" is read as "plus three D B", which
    /// says nothing about the direction the sound moves in.
    ///
    /// Singular at one decibel, which is a rung the reader will land on: the
    /// step is a decibel, so it is the first thing either side of "as recorded".
    public static func spoken(_ decibels: Int) -> String {
        let legal = clamped(decibels)
        if legal == 0 { return "as recorded" }
        let unit = abs(legal) == 1 ? "decibel" : "decibels"
        return legal > 0 ? "\(legal) \(unit) louder" : "\(-legal) \(unit) quieter"
    }
}
