import Foundation
import Testing

@testable import IssaPlayback

/// The player noticing that "playing" is not playing.
///
/// On 17 Nov 2026 a read-along stopped mid-file and the app believed it was
/// playing for two hours, with nothing in the log. Every stop the player makes
/// itself sets `isPlaying` false, so the audio stopped underneath it; these
/// hold the watchdog to noticing that, recovering once, and otherwise stopping
/// honestly — and to leaving alone everything that is meant to be still.
///
/// The engine's clock is held still through `engineClock`, and the checks are
/// driven with explicit instants, so nothing here waits on a real timer.
@MainActor
@Suite("The playback watchdog")
struct AudioPlayerWatchdogTests {
    private func playing() async -> AudioPlayer {
        let player = AudioPlayer()
        player.watchdogInterval = .seconds(3600)  // driven by hand below
        #expect(await player.load(url: SilentAudio.url, href: "silence.wav") == .loaded)
        player.play()
        return player
    }

    /// Waits for a recovery's re-seek to land, so the next check is not read
    /// as a placement still in flight.
    private func settle(_ player: AudioPlayer) async {
        for _ in 0..<100 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a frozen clock is recovered once, and a second freeze stops the book with a reason")
    func frozenThenStopped() async {
        let player = await playing()
        player.engineClock = { 42 }
        let start = ContinuousClock.now

        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(9))
        #expect(player.stallRecoveries == 1, "eight seconds without the clock moving is a stall")
        #expect(player.isPlaying, "the first stall is recovered from, not stopped")

        await settle(player)
        player.checkForStall(now: start + .seconds(10))
        player.checkForStall(now: start + .seconds(19))
        #expect(!player.isPlaying, "a second stall straight after a recovery stops the book")
        #expect(player.stallRecoveries == 1)
    }

    @Test("a clock that is moving is never a stall")
    func movingIsFine() async {
        let player = await playing()
        var time = 10.0
        player.engineClock = { time }
        let start = ContinuousClock.now
        for second in stride(from: 0, through: 30, by: 3) {
            time += 3
            player.checkForStall(now: start + .seconds(second))
        }
        #expect(player.stallRecoveries == 0)
        #expect(player.isPlaying)
    }

    @Test("a paused book is meant to be still, and is left alone")
    func pausedIsLeftAlone() async {
        let player = await playing()
        player.pause()
        player.engineClock = { 42 }
        let start = ContinuousClock.now
        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(60))
        #expect(player.stallRecoveries == 0)
        #expect(!player.isPlaying)
    }

    @Test("an interrupted book is meant to be still, and is left alone")
    func interruptedIsLeftAlone() async {
        let player = await playing()
        player.interruptionBegan()
        player.engineClock = { 42 }
        let start = ContinuousClock.now
        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(60))
        #expect(player.stallRecoveries == 0)
    }

    /// A streamed track buffers as a matter of course, and the player does not
    /// wait to minimise stalls: re-placing it would only thrash.
    @Test("a streamed item's stall is logged, never re-placed or stopped")
    func streamedIsOnlyLogged() async {
        let player = await playing()
        player.currentItemIsFile = false
        player.engineClock = { 42 }
        let start = ContinuousClock.now
        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(9))
        player.checkForStall(now: start + .seconds(20))
        #expect(player.stallRecoveries == 0)
        #expect(player.isPlaying)
    }

    /// `load` zeroes the clock before it awaits the file, so a placement that
    /// never landed was placed again at second 0 — a book opened an hour into
    /// a long file went back to that file's start, and the coordinator, told
    /// the load was overtaken, never corrected the clock.
    @Test("a placement that never lands is placed again where it was going, not at the file's start")
    func stuckPlacementKeepsItsTarget() async {
        let player = AudioPlayer()
        player.watchdogInterval = .seconds(3600)  // driven by hand below
        let target = SilentAudio.duration / 2
        player.whileLoadingAsset = {
            player.play()
            player.checkForStall(now: .now + .seconds(11))
            for _ in 0..<20 { await Task.yield() }
        }
        _ = await player.load(url: SilentAudio.url, href: "silence.wav", startAt: target)
        await settle(player)
        #expect(player.stallRecoveries == 1, "eleven seconds placing is a stuck placement")
        #expect(abs(player.currentTime - target) < 0.01, "re-placed at \(player.currentTime), not \(target)")
    }

    @Test("stopped at the end of a file with no end notification, the file change runs")
    func missedEndRunsTheFileChange() async {
        let player = await playing()
        var ends = 0
        player.onFinishedFile = { ends += 1 }
        player.engineClock = { SilentAudio.duration }
        let start = ContinuousClock.now
        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(9))
        #expect(ends == 1)
        #expect(player.stallRecoveries == 1)
    }
}
