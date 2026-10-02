import AVFoundation
import Foundation
import Testing

@testable import IssaPlayback

/// The player's own contract with whoever drives it: which call owns the item,
/// which owns the playhead, and what a file that will not play does to both.
@Suite("The player's item and playhead")
@MainActor
struct AudioPlayerEpochTests {
    /// A clip time is whatever the overlay says. `SMILClock` refuses only the
    /// non-finite and the negative, so `clipBegin="1e20s"` reaches the player,
    /// and so does a manifest track that claims `1e300` seconds. The seek
    /// converted with `CMTimeValue(Double)`, which traps past `Int64.max / 600`
    /// seconds — about 1.5e16 — and on infinity: a malformed book crashed the
    /// app on every attempt to open it at that sentence.
    @Test("a seek to a time no file could hold does not trap", arguments: [
        1.6e16, 1e20, 1e300, TimeInterval.infinity,
    ])
    func anAbsurdSeekDoesNotTrap(seconds: TimeInterval) async {
        let player = AudioPlayer()
        await player.load(url: SilentAudio.url, href: "silence.wav")

        await player.seek(to: seconds)

        #expect(player.currentTime.isFinite)
    }

    /// The conversion on its own: saturating where it used to trap, and the
    /// round-up every ordinary target depends on left exactly as it was.
    @Test("a seek target saturates past what the timescale holds, and still rounds up")
    func seekTargetsSaturateAndRoundUp() {
        for seconds: TimeInterval in [1.6e16, 1e20, 1e300, .infinity] {
            let target = AudioPlayer.cmTime(forSeconds: seconds)
            #expect(target.isValid && target.isNumeric, "\(seconds) s became \(target)")
            #expect(target.value == .max)
        }
        // The largest that still fits is still exact.
        #expect(AudioPlayer.cmTime(forSeconds: 1.5e16).value == 9_000_000_000_000_000_000)
        #expect(AudioPlayer.cmTime(forSeconds: 4.25) == CMTime(value: 2_550, timescale: 600))
        #expect(AudioPlayer.cmTime(forSeconds: 4.2501) == CMTime(value: 2_551, timescale: 600),
                "up, never to nearest")
        #expect(AudioPlayer.cmTime(forSeconds: -3) == CMTime(value: 0, timescale: 600))
        #expect(AudioPlayer.cmTime(forSeconds: .nan) == .zero)
    }
}
