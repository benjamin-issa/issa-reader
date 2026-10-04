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

    // MARK: - A file that will not play

    /// A file AVFoundation cannot open: the shape a `.files` chunk deleted from
    /// disk has, and a streamed track whose request failed.
    static func missingFile() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-missing-\(UUID().uuidString).mp3")
    }

    /// The player was told to play, the next file would not open, and it said
    /// nothing: `load` reported success, `isPlaying` stayed true, and every
    /// surface drew a pause glyph over silence while the sleep timer counted.
    @Test("a file that will not open stops the player rather than playing silence")
    func aFileThatWillNotOpenStopsThePlayer() async {
        let player = AudioPlayer()
        player.play()

        let outcome = await player.load(url: Self.missingFile(), href: "missing.mp3", startAt: 30)

        #expect(outcome == .failed)
        #expect(player.isPlaying == false, "a player holding nothing it can play claimed to be playing")
        #expect(player.engineRate == 0)
    }

    /// A failure reported for an item a later load has already replaced is
    /// about audio nobody is listening to.
    @Test("a failure reported for a replaced item stops nothing")
    func aStaleFailureStopsNothing() async {
        let player = AudioPlayer()
        await player.load(url: SilentAudio.url, href: "older.wav")
        let olderItem = player.itemGenerationForTests
        await player.load(url: SilentAudio.url, href: "newer.wav")
        player.play()

        player.itemDidFail(generation: olderItem, reason: "test")
        #expect(player.isPlaying, "the item playing now did not fail")

        // And the item playing now failing does stop it — the path the status
        // observer and the failed-to-play notification both take.
        player.itemDidFail(generation: player.itemGenerationForTests, reason: "test")
        #expect(player.isPlaying == false)
    }

    // MARK: - Which call owns the playhead

    /// A seek into the file a load is still opening. The load used to wake up,
    /// find no newer *load*, and run its own trailing seek over the newer one.
    @Test("a seek made while a load opens its file owns the playhead, and the load says so")
    func aSeekDuringALoadOvertakesIt() async {
        let player = AudioPlayer()
        player.whileLoadingAsset = { await player.seek(to: 7) }

        let outcome = await player.load(url: SilentAudio.url, href: "silence.wav", startAt: 300)

        #expect(outcome == .overtaken)
        #expect(abs(player.currentTime - 7) < 0.01, "the load's own offset was written over the seek")
        #expect(abs(player.engineTime - 7) < 0.01, "the engine ran the load's trailing seek: \(player.engineTime)")
        // The item is still this load's, and what describes it was written.
        #expect(player.currentAudioHref == "silence.wav")
        #expect(player.duration == SilentAudio.duration)
    }

    /// A load another load replaced. It owns nothing, and writes nothing.
    @Test("a load another load replaced writes nothing")
    func aSupersededLoadWritesNothing() async {
        let player = AudioPlayer()
        var newer: AudioPlayer.LoadOutcome?
        player.whileLoadingAsset = {
            newer = await player.load(url: SilentAudio.url, href: "newer.wav", startAt: 42)
        }

        let older = await player.load(url: SilentAudio.url, href: "older.wav", startAt: 300)

        #expect(older == .superseded)
        #expect(newer == .loaded)
        #expect(player.currentAudioHref == "newer.wav")
        #expect(abs(player.currentTime - 42) < 0.01)
        #expect(abs(player.engineTime - 42) < 0.01, "the superseded load seeked the newer item: \(player.engineTime)")
    }

    /// A seek that completes after something newer took the playhead: the
    /// trailing seek of a load the next load interrupted, which AVFoundation
    /// calls back with `finished == false`. It wrote the clock and restored
    /// the rate regardless, so the new item started from its first second with
    /// the old file's time on the clock.
    ///
    /// The clock is not asserted mid-window: the engine really does move for
    /// the stale seek here, and the periodic observer reports every time jump,
    /// so it can legitimately show 500 until the newer load's own seek lands.
    /// What the guard owns is the answer and the rate.
    @Test("a seek something newer overtook does not claim the playhead or start the engine")
    func anOvertakenSeekWritesNothing() async {
        let player = AudioPlayer()
        await player.load(url: SilentAudio.url, href: "older.wav", startAt: 60)
        player.play()
        let issuedBefore = player.playheadGeneration
        var owned: Bool?
        var rateWhileLanding: Float?
        player.whileLoadingAsset = {
            // The older seek completing inside the newer load's window.
            owned = await player.seekPlayhead(500, generation: issuedBefore)
            rateWhileLanding = player.engineRate
        }

        await player.load(url: SilentAudio.url, href: "newer.wav", startAt: 42)

        #expect(owned == false, "a seek something newer overtook claimed the playhead")
        #expect(rateWhileLanding == 0, "the stale seek started the new item before it was placed")
        #expect(abs(player.currentTime - 42) < 0.01)
        #expect(player.engineRate == player.rate, "and the newer load started it once placed")
    }

    /// Play — or a new speed — pressed while a chapter is opening. Either one
    /// set the engine's rate straight away, so the new item played from its
    /// first second until the load's seek landed: for a streamed track, a
    /// network round trip of the wrong audio.
    @Test("play pressed while a load is placing its item waits for the placement")
    func playDuringALoadWaitsForThePlacement() async {
        let player = AudioPlayer()
        var afterPlay: Float?
        var afterRate: Float?
        player.whileLoadingAsset = {
            player.play()
            afterPlay = player.engineRate
            player.rate = 1.5
            afterRate = player.engineRate
        }

        let outcome = await player.load(url: SilentAudio.url, href: "silence.wav", startAt: 120)

        #expect(outcome == .loaded)
        #expect(afterPlay == 0, "play started the new item before its seek had landed")
        #expect(afterRate == 0, "a new speed started it too")
        #expect(player.isPlaying, "the intent is kept")
        #expect(player.engineRate == 1.5, "and the placement honours the speed chosen meanwhile")
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
