import Foundation
import Testing

@testable import IssaPlayback

/// One statement of what a per-book level may be.
///
/// The slider, the Mac's ⌘⌥↑/↓ and the stored preference all reach this, and
/// each of them can hand it a value it did not ask for: a drag in flight, a
/// nudge off the end of the range, a defaults blob written by an older build.
@Suite("Trimming a book's volume")
struct VolumeTrimTests {
    /// Snapped first, then clamped — and the order is only visible outside the
    /// range, where the two disagree. Every integer decibel is a rung, so
    /// nothing inside the range has anywhere to snap to; what the arithmetic is
    /// still for is the values that arrive from outside it.
    @Test("a level is snapped to the nearest rung and then clamped", arguments: [
        (0, 0), (1, 1), (-1, -1), (3, 3), (-6, -6), (8, 8), (-8, -8),
        (9, 8), (-9, -8), (100, 8), (-100, -8), (500, 8),
    ])
    func stepping(input: Int, expected: Int) {
        #expect(VolumeTrim.clamped(input) == expected)
    }

    /// Whatever a caller hands it, what comes back is a level the slider can
    /// draw and the ladder contains. The sweep is wider than the range on
    /// purpose: the percentages a previous build stored ran to ±50.
    @Test("every level clamps onto a rung the ladder actually has")
    func alwaysLandsOnTheLadder() {
        #expect(VolumeTrim.ladder.count == 17)
        #expect(VolumeTrim.ladder.first == -8)
        #expect(VolumeTrim.ladder.last == 8)
        #expect(VolumeTrim.ladder == VolumeTrim.ladder.map(VolumeTrim.clamped),
                "a rung is not a fixed point of the clamp")
        for level in -60 ... 60 {
            #expect(VolumeTrim.ladder.contains(VolumeTrim.clamped(level)),
                    "\(level) clamped to something the slider cannot show")
        }
    }

    @Test("the ends of the range are the ends of the gain range")
    func gains() {
        #expect(VolumeTrim.gain(0) == 1)
        #expect(abs(VolumeTrim.gain(8) - 2.511_886_4) < 1e-5)
        #expect(abs(VolumeTrim.gain(-8) - 0.398_107_2) < 1e-5)
        #expect(VolumeTrim.gain(8) == VolumeTrim.gainRange.upperBound)
        #expect(VolumeTrim.gain(-8) == VolumeTrim.gainRange.lowerBound)
        // Out of range on the way in, in range on the way out: a nudge past the
        // end must not be allowed to leak a gain past the end.
        #expect(VolumeTrim.gain(500) == VolumeTrim.gain(8))
    }

    /// The reason the scale changed, and the assertion no range or bounds test
    /// can make. On the percentage scale it shipped at, −50 → −45% was 0.83 dB
    /// while +45 → +50% was 0.29 dB — and the just-noticeable difference on
    /// speech is about 1 dB, so every detent on the upper half did nothing a
    /// reader could hear. Here every click is the same size, and that size is
    /// one JND.
    @Test("consecutive rungs are one decibel apart, wherever on the slider they are")
    func everyRungIsTheSameSize() {
        for (lower, upper) in zip(VolumeTrim.ladder, VolumeTrim.ladder.dropFirst()) {
            let step = 20 * log10(VolumeTrim.gain(upper) / VolumeTrim.gain(lower))
            #expect(abs(step - 1) < 0.05, "\(lower) dB → \(upper) dB is a step of \(step) dB")
        }
        // And the top rung is the "up to 150% louder" that was asked for.
        #expect(abs((VolumeTrim.gain(8) - 1) * 100 - 151.2) < 0.5)
    }

    /// A NaN reaching the tap would multiply every sample into nothing, with
    /// no control on screen able to explain or undo it.
    @Test("a gain that is not a number reads as as-recorded")
    func nonFiniteGain() {
        #expect(VolumeTrim.clampedGain(.nan) == 1)
        #expect(VolumeTrim.clampedGain(.infinity) == 1)
        #expect(VolumeTrim.clampedGain(-.infinity) == 1)
        #expect(VolumeTrim.clampedGain(9) == VolumeTrim.gainRange.upperBound)
        #expect(VolumeTrim.clampedGain(0) == VolumeTrim.gainRange.lowerBound)
        #expect(VolumeTrim.clampedGain(1.1) == 1.1)
    }

    /// Every level a shipped build could have written, converted, and measured
    /// against the multiplier the reader was actually hearing. The rounding to
    /// the nearest rung is what moves it, and half a decibel is half a
    /// just-noticeable difference: nobody hears the upgrade happen.
    @Test("a stored percentage converts to the level it was already playing at")
    func legacyPercentagesKeepTheirMeaning() {
        var worst = 0.0
        for percent in stride(from: -50, through: 50, by: 5) {
            let wasPlayingAt = 1 + Double(percent) / 100
            let nowPlaysAt = Double(VolumeTrim.gain(VolumeTrim.decibels(forLegacyPercent: percent)))
            let shift = abs(20 * log10(nowPlaysAt / wasPlayingAt))
            worst = max(worst, shift)
            #expect(shift < 0.5, "\(percent)% moved by \(shift) dB")
        }
        #expect(abs(worst - 0.4988) < 0.001, "the worst shift is not where it was measured, \(worst)")
    }

    /// The values that matter most, spelled out: the two ends of the old slider
    /// and the ±30% it shipped at before that.
    @Test("the levels a reader is most likely to have stored", arguments: [
        (-50, -6), (-30, -3), (-25, -2), (-15, -1), (0, 0), (5, 0),
        (15, 1), (25, 2), (30, 2), (50, 4),
    ])
    func namedLegacyLevels(percent: Int, decibels: Int) {
        #expect(VolumeTrim.decibels(forLegacyPercent: percent) == decibels)
    }

    /// A blob on disk is a file, and a file can say anything. −100% is silence
    /// and anything under it is a phase inversion; neither was ever a level a
    /// control offered, and `log10` of either is not a number `Int` can hold.
    @Test("a percentage no control could produce still converts to a legal level", arguments: [
        -100, -101, -1000, Int.min / 2, 1000, Int.max / 2,
    ])
    func absurdLegacyPercentages(percent: Int) {
        #expect(VolumeTrim.range.contains(VolumeTrim.decibels(forLegacyPercent: percent)))
    }

    @Test("the label reads as recorded at zero and signs itself either side")
    func labels() {
        #expect(VolumeTrim.label(0) == "As recorded")
        #expect(VolumeTrim.label(3) == "+3 dB")
        // U+2212 MINUS SIGN, which is what sits level with the plus in a
        // monospaced-digit face. A hyphen would be shorter and lower.
        #expect(VolumeTrim.label(-6) == "\u{2212}6 dB")
        #expect(VolumeTrim.label(-6).contains("-") == false)
        #expect(VolumeTrim.label(-8) == "\u{2212}8 dB")
        #expect(VolumeTrim.label(8) == "+8 dB")
        // The row's ticks are read off the range, so widening it cannot leave
        // the slider going one place and its own captions promising another.
        #expect(VolumeTrim.label(VolumeTrim.range.lowerBound) == "\u{2212}8 dB")
        #expect(VolumeTrim.label(VolumeTrim.range.upperBound) == "+8 dB")
    }

    @Test("the spoken form says which way the sound moves")
    func spoken() {
        #expect(VolumeTrim.spoken(0) == "as recorded")
        #expect(VolumeTrim.spoken(3) == "3 decibels louder")
        #expect(VolumeTrim.spoken(-6) == "6 decibels quieter")
        #expect(VolumeTrim.spoken(-8) == "8 decibels quieter")
        #expect(VolumeTrim.spoken(8) == "8 decibels louder")
        // The step is one decibel, so ±1 is the first rung either side of "as
        // recorded" and the one a reader lands on most.
        #expect(VolumeTrim.spoken(1) == "1 decibel louder")
        #expect(VolumeTrim.spoken(-1) == "1 decibel quieter")
    }
}
