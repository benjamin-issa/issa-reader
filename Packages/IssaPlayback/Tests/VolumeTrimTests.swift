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
    /// Snapped first, then clamped — and the order is only visible just outside
    /// the range, where the two disagree. 33 snaps up to 35, which is not a
    /// level this app offers, so it lands on the end of the range rather than
    /// three percent past it. (The plan's table wanted 35 there, which cannot
    /// hold alongside its own 100 → 30 and −45 → −30: a range with a ceiling has
    /// one for every value.)
    @Test("a percentage is snapped to the nearest step and then clamped", arguments: [
        (23, 25), (22, 20), (21, 20), (-23, -25),
        (33, 30), (-33, -30), (-45, -30), (100, 30), (0, 0),
        (30, 30), (-30, -30), (5, 5), (-2, 0),
    ])
    func stepping(input: Int, expected: Int) {
        #expect(VolumeTrim.clamped(input) == expected)
    }

    @Test("the ends of the range are the ends of the gain range")
    func gains() {
        #expect(VolumeTrim.gain(0) == 1)
        #expect(VolumeTrim.gain(30) == 1.3)
        #expect(VolumeTrim.gain(-30) == 0.7)
        #expect(VolumeTrim.gain(30) == VolumeTrim.gainRange.upperBound)
        #expect(VolumeTrim.gain(-30) == VolumeTrim.gainRange.lowerBound)
        // Out of range on the way in, in range on the way out: a nudge past the
        // end must not be allowed to leak a gain past the end.
        #expect(VolumeTrim.gain(500) == 1.3)
    }

    /// A NaN reaching the tap would multiply every sample into nothing, with
    /// no control on screen able to explain or undo it.
    @Test("a gain that is not a number reads as as-recorded")
    func nonFiniteGain() {
        #expect(VolumeTrim.clampedGain(.nan) == 1)
        #expect(VolumeTrim.clampedGain(.infinity) == 1)
        #expect(VolumeTrim.clampedGain(-.infinity) == 1)
        #expect(VolumeTrim.clampedGain(9) == 1.3)
        #expect(VolumeTrim.clampedGain(0) == 0.7)
        #expect(VolumeTrim.clampedGain(1.1) == 1.1)
    }

    @Test("the label reads as recorded at zero and signs itself either side")
    func labels() {
        #expect(VolumeTrim.label(0) == "As recorded")
        #expect(VolumeTrim.label(15) == "+15%")
        // U+2212 MINUS SIGN, which is what sits level with the plus in a
        // monospaced-digit face. A hyphen would be shorter and lower.
        #expect(VolumeTrim.label(-15) == "\u{2212}15%")
        #expect(VolumeTrim.label(-15).contains("-") == false)
        #expect(VolumeTrim.label(-30) == "\u{2212}30%")
        #expect(VolumeTrim.label(30) == "+30%")
    }

    @Test("the spoken form says which way the sound moves")
    func spoken() {
        #expect(VolumeTrim.spoken(0) == "as recorded")
        #expect(VolumeTrim.spoken(15) == "15 percent louder")
        #expect(VolumeTrim.spoken(-10) == "10 percent quieter")
        #expect(VolumeTrim.spoken(-30) == "30 percent quieter")
    }
}
