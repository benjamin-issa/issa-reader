import Foundation
import Testing

@testable import IssaReader_iOS

/// How the player says how much of a book is left.
///
/// The line under the scrubber is `4h 12m left in book · 42%`, and the only
/// part of it with any logic is the duration. `PlayerView.timeText` — the
/// function that was already there — prints `4:12:00`, which is a correct clock
/// reading and the wrong thing to put beside a scrubber: a colon-separated
/// figure reads as a *position* in the book rather than an amount of it left.
/// So there is a second formatter, and this is what pins it.
@Suite("Saying how much of the book is left")
@MainActor
struct BookReadoutTests {
    @Test(
        "a length reads in units, not as a clock",
        arguments: [
            (4 * 3600 + 12 * 60 as TimeInterval, "4h 12m"),
            (47 * 60 as TimeInterval, "47m"),
            // On the hour, and the zero minutes are kept: "1h" alone next to
            // "4h 12m" reads like a different, coarser measurement.
            (3600 as TimeInterval, "1h 0m"),
            (0 as TimeInterval, "0m"),
        ])
    func durationText(_ seconds: TimeInterval, _ expected: String) {
        #expect(PlayerView.durationText(seconds) == expected)
    }

    /// Rounded to the nearest minute rather than truncated, so a book with
    /// 4h12m50s left does not claim 4h 12m for most of a minute.
    @Test("seconds round rather than truncate")
    func rounding() {
        #expect(PlayerView.durationText(4 * 3600 + 12 * 60 + 50) == "4h 13m")
        #expect(PlayerView.durationText(4 * 3600 + 12 * 60 + 10) == "4h 12m")
    }

    /// Nothing may reach `Int()` that would trap it, and a negative or
    /// non-finite duration must not print a minus sign at a listener.
    ///
    /// `1e300` is the case this suite claimed to cover and did not: it is
    /// finite, so it walked past an `isFinite` guard and trapped in
    /// `Int((seconds / 60).rounded())`. Both readouts are handed the same
    /// number, so both are asked.
    @Test("nothing sensible comes back from a nonsense duration, and nothing crashes")
    func nonsense() {
        #expect(PlayerView.durationText(-60) == "0m")
        #expect(PlayerView.durationText(.nan) == "0m")
        #expect(PlayerView.durationText(.infinity) == "0m")
        #expect(PlayerView.durationText(1e300) == "0m")
        #expect(PlayerView.spokenDuration(-60) == "no time")
        #expect(PlayerView.spokenDuration(.nan) == "no time")
        #expect(PlayerView.spokenDuration(.infinity) == "no time")
        #expect(PlayerView.spokenDuration(1e300) == "no time")
    }

    /// The clock above the bar, which reads a position rather than an amount.
    @Test(
        "a position reads as a clock, with the hour dropped under one",
        arguments: [
            (0 as TimeInterval, "0:00"),
            (7 as TimeInterval, "0:07"),
            (67 as TimeInterval, "1:07"),
            (47 * 60 + 31 as TimeInterval, "47:31"),
            (4 * 3600 + 12 * 60 as TimeInterval, "4:12:00"),
            (3600 as TimeInterval, "1:00:00"),
        ])
    func timeText(_ seconds: TimeInterval, _ expected: String) {
        #expect(PlayerView.timeText(seconds) == expected)
    }

    /// The same trap as `durationText`, in the same file, and missed when that
    /// one was fixed.
    ///
    /// `timeText` guarded `isFinite` and stopped there — exactly what
    /// `IssaCore.DurationText`'s comment names as insufficient. `1e300` is
    /// finite and greater than zero, so it walked past the guard and trapped in
    /// `Int(seconds.rounded())`. Both readings above the scrubber are
    /// `total * progress` over a duration that came off the wire, so this is
    /// the player crashing as it draws rather than a wrong number.
    @Test("a nonsense position prints nothing rather than crashing the player")
    func nonsensePosition() {
        #expect(PlayerView.timeText(1e300) == "0:00")
        #expect(PlayerView.timeText(.nan) == "0:00")
        #expect(PlayerView.timeText(.infinity) == "0:00")
        #expect(PlayerView.timeText(-.infinity) == "0:00")
        #expect(PlayerView.timeText(-60) == "0:00")
        // The two the player actually computes: a fraction of a poisoned
        // duration, and the remainder of one.
        #expect(PlayerView.timeText(1e300 * 0.5) == "0:00")
        #expect(PlayerView.timeText(1e300 * (1 - 0.5)) == "0:00")
        // Still a real answer either side of the largest length a book has.
        #expect(PlayerView.timeText(99 * 3600) == "99:00:00")
    }

    /// VoiceOver gets words. Handing it `4h 12m` makes it say "four aitch
    /// twelve em", which is the failure this exists to prevent.
    @Test(
        "the spoken form is words, and singular where it should be",
        arguments: [
            (4 * 3600 + 12 * 60 as TimeInterval, "4 hours 12 minutes"),
            (3600 as TimeInterval, "1 hour"),
            (60 as TimeInterval, "1 minute"),
            (47 * 60 as TimeInterval, "47 minutes"),
            (2 * 3600 + 60 as TimeInterval, "2 hours 1 minute"),
        ])
    func spokenDuration(_ seconds: TimeInterval, _ expected: String) {
        #expect(PlayerView.spokenDuration(seconds) == expected)
    }
}
