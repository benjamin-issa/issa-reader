import Foundation

/// How far one book's level may depart from the level it was recorded at.
///
/// Self-hosted libraries are assembled from whatever the reader could find, so
/// one book is mastered six decibels under the next and the listener rides the
/// hardware volume between them. This is the per-book correction: a percentage
/// either side of "as recorded", stated once so the slider, the Mac's ⌘⌥↑/↓ and
/// the stored preference cannot disagree about what is legal — the same defect
/// `PlaybackRate` exists to close for speed.
///
/// Percentages rather than decibels: the control is a slider a reader nudges by
/// ear, and ±30% is a change they can hear without being a change that ruins the
/// recording. The gain that carries it is ±0.3 around unity, so 0 costs nothing
/// at all — the tap short-circuits at exactly 1.
public enum VolumeTrim {
    /// The legal percentages, either side of the recorded level.
    public static let range: ClosedRange<Int> = -30 ... 30
    /// The detent spacing. Five percent is about the smallest step that is
    /// audible on speech, so a finer slider would only offer values that feel
    /// like nothing happened.
    public static let step = 5
    /// The multipliers `range` maps onto, named so a caller clamping a raw
    /// float does not have to rederive them.
    public static let gainRange: ClosedRange<Float> = 0.7 ... 1.3

    /// The nearest legal percentage.
    ///
    /// Snapped before it is clamped, because both ends have to hold: a slider
    /// with a `step` still hands back the odd unsnapped value while a drag is in
    /// flight, and a nudge or a restored preference can arrive from outside the
    /// range entirely.
    public static func clamped(_ percent: Int) -> Int {
        let snapped = Int((Double(percent) / Double(step)).rounded()) * step
        return Swift.min(Swift.max(snapped, range.lowerBound), range.upperBound)
    }

    /// The multiplier a percentage stands for: 0 → 1, +30 → 1.3, −30 → 0.7.
    public static func gain(_ percent: Int) -> Float {
        1 + Float(clamped(percent)) / 100
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

    /// What the row shows on the right: "As recorded", "+15%" or "−15%".
    ///
    /// U+2212 MINUS SIGN, not a hyphen: the value is set in a monospaced-digit
    /// face beside a "+" of the same width, and a hyphen is visibly shorter and
    /// sits lower than the plus it alternates with.
    public static func label(_ percent: Int) -> String {
        let legal = clamped(percent)
        if legal == 0 { return "As recorded" }
        return legal > 0 ? "+\(legal)%" : "\u{2212}\(-legal)%"
    }

    /// What VoiceOver says instead. "+15%" is read as "plus fifteen percent",
    /// which says nothing about the direction the sound moves in.
    public static func spoken(_ percent: Int) -> String {
        let legal = clamped(percent)
        if legal == 0 { return "as recorded" }
        return legal > 0 ? "\(legal) percent louder" : "\(-legal) percent quieter"
    }
}
