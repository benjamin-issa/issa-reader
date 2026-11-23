import AVFoundation
import Foundation
import Testing

@testable import IssaPlayback

/// The player building itself a new engine when the old one dies.
///
/// On 21 Nov 2026 a listener took a phone call during narration, pressed play
/// afterwards, and the button said "playing" over silence with no message.
/// iOS had restarted its media services (-11819), which leaves every
/// `AVPlayer` a shell that takes a rate and makes no sound; the player kept
/// its one engine for life, and the reset handler re-seeked it. These hold the
/// player to replacing the engine — where the book was, as it was set, and
/// playing only if it was — and to finding a start that makes no sound,
/// rebuilding once, and otherwise stopping and saying so.
///
/// A real reset cannot be staged here: the notice is delivered by calling its
/// handler, the dead engine is stood in for through `engineTimeControl`,
/// `engineClock` and `markEngineFailedForTests`, and the start check is driven
/// by hand with explicit instants.
///
/// One at a time: each test runs a real engine, several rebuild it, and a
/// dozen of them playing at once slowed the run enough to push the timing
/// suites beside them past their windows.
@MainActor
@Suite("Rebuilding a dead audio engine", .serialized)
struct AudioPlayerRebuildTests {
    private static let place: TimeInterval = 600

    /// A player with silence loaded at `place`, its timers driven by hand.
    private func loaded(at place: TimeInterval = Self.place) async -> AudioPlayer {
        let player = AudioPlayer()
        player.watchdogInterval = .seconds(3600)
        player.startCheckDelay = .seconds(3600)
        #expect(await player.load(url: SilentAudio.url, href: "silence.wav", startAt: place) == .loaded)
        return player
    }

    private func rebuilt(_ player: AudioPlayer) async {
        await player.rebuildTask?.value
    }

    /// The look a second after a start, as the timer would take it.
    private func checkAfterStart(_ player: AudioPlayer) {
        player.checkStart(now: .now + .seconds(1))
    }

    // MARK: - The rebuild

    @Test("a rebuild under a playing book puts it back where it was, as it was set, and playing")
    func rebuildWhilePlaying() async {
        let player = await loaded()
        player.rate = 1.5
        player.gain = 1.5
        player.volume = 0.6
        player.play()
        let engine = player.engineIdentity
        let tap = player.tapCarriesGain
        let underlying = player.underlyingVolume
        try? #require(tap != nil)

        player.mediaServicesWereReset()
        await rebuilt(player)

        #expect(player.engineIdentity != engine, "the dead engine was kept")
        #expect(player.rebuilds == 1)
        #expect(abs(player.currentTime - Self.place) < 0.05, "reopened at \(player.currentTime)")
        #expect(abs(player.engineTime - Self.place) < 0.05, "the engine is at \(player.engineTime)")
        #expect(player.isPlaying)
        #expect(player.engineRate == 1.5, "the rate was lost")
        #expect(player.gain == 1.5)
        #expect(player.tapCarriesGain == tap, "the boost no longer reaches the samples the way it did")
        #expect(player.underlyingVolume == underlying, "the volume was lost")
        #expect(player.currentAudioHref == "silence.wav")
        #expect(player.startFailure == nil)
    }

    @Test("a rebuild under a paused book leaves it paused, where it was")
    func rebuildWhilePaused() async {
        let player = await loaded()
        let engine = player.engineIdentity

        player.mediaServicesWereReset()
        await rebuilt(player)

        #expect(player.engineIdentity != engine)
        #expect(!player.isPlaying, "a paused book started by itself")
        #expect(player.engineRate == 0)
        #expect(abs(player.currentTime - Self.place) < 0.05)
        #expect(player.startFailure == nil)
    }

    @Test("two rebuild requests back to back are one rebuild")
    func backToBack() async {
        let player = await loaded()
        player.play()
        let oldItem = player.itemGenerationForTests

        player.mediaServicesWereReset()
        let engine = player.engineIdentity
        player.mediaServicesWereReset()
        // The old item's own report of the same reset, arriving late.
        player.itemDidStop(generation: oldItem, reason: "test", servicesReset: true)
        await rebuilt(player)

        #expect(player.rebuilds == 1)
        #expect(player.engineIdentity == engine, "the second request threw away the first's engine")
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - Self.place) < 0.05)
    }

    @Test("an item that reports the reset rebuilds the engine rather than standing the book down")
    func itemResetRebuilds() async {
        let player = await loaded()
        player.play()
        let engine = player.engineIdentity

        player.itemDidStop(
            generation: player.itemGenerationForTests, reason: "test", servicesReset: true)
        await rebuilt(player)

        #expect(player.engineIdentity != engine)
        #expect(player.isPlaying, "the item's failure lost that the book was playing")
        #expect(!player.itemHasFailed)
        #expect(player.startFailure == nil)
    }

    @Test("an engine that goes failed is rebuilt")
    func failedEngineRebuilds() async {
        let player = await loaded()
        player.play()
        let engine = player.engineIdentity

        player.engineFailed(engine: player.engineGeneration, reason: "test")
        await rebuilt(player)

        #expect(player.engineIdentity != engine)
        #expect(player.isPlaying)
    }

    @Test("a pause while the rebuild reopens the file stays paused")
    func pauseDuringRebuild() async {
        let player = await loaded()
        player.play()
        player.whileLoadingAsset = { player.pause() }

        player.mediaServicesWereReset()
        await rebuilt(player)

        #expect(!player.isPlaying, "the rebuild played over the listener's pause")
        #expect(player.engineRate == 0)
        #expect(abs(player.currentTime - Self.place) < 0.05)
    }

    @Test("an interruption under way when the engine is rebuilt still resumes the book when it ends")
    func interruptionLatchSurvives() async {
        let player = await loaded()
        player.play()
        player.interruptionBegan()

        player.mediaServicesWereReset()
        await rebuilt(player)
        #expect(!player.isPlaying, "the rebuild played over a call")

        player.interruptionEnded(shouldResume: true)
        #expect(player.isPlaying, "the end of the call did not resume the book on the new engine")
        #expect(player.engineRate == player.rate)
    }

    /// The new engine's clock reads zero while its item opens. A tick then,
    /// handed on, jumped the read-along highlight to the file's first
    /// sentence, turned the page back and told the sleep timer a chapter had
    /// ended. One is delivered from inside the rebuild's load, where a real
    /// one lands, and so is one from the engine already thrown away.
    @Test("no time of zero reaches the coordinator while the engine is rebuilt")
    func noZeroDuringRebuild() async {
        let player = await loaded()
        player.setHighFrequencyUpdates(true)
        var times: [TimeInterval] = []
        player.onTimeUpdate = { times.append($0) }
        player.play()
        let oldEngine = player.engineGeneration
        var clockWhileOpening: TimeInterval?
        player.whileLoadingAsset = {
            clockWhileOpening = player.currentTime
            player.engineTicked(0, engine: player.engineGeneration)
            player.engineTicked(0, engine: oldEngine)
        }

        player.mediaServicesWereReset()
        await rebuilt(player)
        player.engineTicked(0, engine: oldEngine)
        // And a moment of the new engine's own ticks.
        try? await Task.sleep(for: .milliseconds(500))

        #expect(!times.contains { $0 < Self.place - 0.05 },
                "the coordinator was told \(times.filter { $0 < Self.place - 0.05 })")
        #expect(clockWhileOpening == Self.place, "the clock read \(String(describing: clockWhileOpening)) while the file reopened")
        #expect(player.isPlaying)
    }

    @Test("a streamed item gets the same rebuild")
    func streamedRebuilds() async {
        let player = await loaded()
        player.currentItemIsFile = false
        player.play()
        let engine = player.engineIdentity

        player.mediaServicesWereReset()
        await rebuilt(player)

        #expect(player.engineIdentity != engine)
        #expect(player.isPlaying)
        #expect(abs(player.currentTime - Self.place) < 0.05)
    }

    @Test("a rebuild whose file will not reopen stops the book and says the audio stopped")
    func reopenFails() async {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-rebuild-\(UUID().uuidString).wav")
        try? FileManager.default.copyItem(at: SilentAudio.url, to: missing)
        let player = AudioPlayer()
        player.startCheckDelay = .seconds(3600)
        player.watchdogInterval = .seconds(3600)
        #expect(await player.load(url: missing, href: "gone.wav", startAt: 30) == .loaded)
        player.play()
        try? FileManager.default.removeItem(at: missing)

        player.mediaServicesWereReset()
        await rebuilt(player)

        #expect(!player.isPlaying)
        #expect(player.startFailure == .audioStopped)
    }

    // MARK: - The start check

    @Test("a start the engine leaves paused is rebuilt once, then stopped with a reason")
    func deadStartRebuildsOnceThenStops() async {
        let player = await loaded()
        var told: [AudioPlayer.StartFailure?] = []
        player.onStartFailure = { told.append($0) }
        player.engineTimeControl = { .paused }
        player.play()
        let engine = player.engineIdentity

        checkAfterStart(player)
        await rebuilt(player)
        #expect(player.rebuilds == 1, "a dead start was not rebuilt")
        #expect(player.engineIdentity != engine)
        #expect(player.isPlaying, "the rebuild's own start is given its chance")

        checkAfterStart(player)
        await rebuilt(player)
        #expect(player.rebuilds == 1, "a second rebuild for the same start")
        #expect(!player.isPlaying, "still drawn as playing over silence")
        #expect(player.startFailure == .audioStopped)
        #expect(told.last == .audioStopped, "nobody was told: \(told)")
    }

    @Test("a dead start that the rebuild brings back plays on, and says nothing")
    func deadStartRecovered() async {
        let player = await loaded()
        player.engineTimeControl = { .paused }
        player.play()

        checkAfterStart(player)
        await rebuilt(player)
        #expect(player.rebuilds == 1)
        // The new engine moves.
        player.engineClock = { Self.place + 1 }
        player.engineTimeControl = { .playing }
        checkAfterStart(player)

        #expect(player.isPlaying)
        #expect(player.startFailure == nil)
        #expect(player.rebuilds == 1)
    }

    @Test("a failed engine is a dead start")
    func failedEngineIsDead() async {
        let player = await loaded()
        player.play()
        player.markEngineFailedForTests()

        checkAfterStart(player)
        await rebuilt(player)

        #expect(player.rebuilds == 1)
    }

    @Test("a local file whose clock has not moved is a dead start")
    func stillClockIsDead() async {
        let player = await loaded()
        player.engineClock = { Self.place }
        player.engineTimeControl = { .playing }
        player.play()

        checkAfterStart(player)
        await rebuilt(player)

        #expect(player.rebuilds == 1)
    }

    @Test("buffering is never a dead start")
    func bufferingIsNotDead() async {
        let player = await loaded()
        player.engineClock = { Self.place }
        player.engineTimeControl = { .waitingToPlayAtSpecifiedRate }
        player.play()

        checkAfterStart(player)
        checkAfterStart(player)

        #expect(player.rebuilds == 0)
        #expect(player.isPlaying)
        #expect(player.startFailure == nil)
    }

    @Test("a start that plays is left alone")
    func playingIsNotDead() async {
        let player = await loaded()
        var time = Self.place
        player.engineClock = { time }
        player.engineTimeControl = { .playing }
        player.play()
        time += 1

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
        #expect(player.isPlaying)
    }

    /// A stream that has run dry reports waiting, and is still filling its
    /// buffer rather than dead — however long its clock has stood still.
    @Test("a buffering stream is never a dead start, whatever its clock says")
    func bufferingStreamIsNotDead() async {
        let player = await loaded()
        player.currentItemIsFile = false
        player.engineClock = { Self.place }
        player.engineTimeControl = { .waitingToPlayAtSpecifiedRate }
        player.play()

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
        #expect(player.isPlaying)
        #expect(player.startFailure == nil)
    }

    @Test("a stream that says it is playing is not judged by a clock that has not moved yet")
    func streamIsJudgedByStatusAlone() async {
        let player = await loaded()
        player.currentItemIsFile = false
        player.engineClock = { Self.place }
        player.engineTimeControl = { .playing }
        player.play()

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
    }

    /// The read-along keeps `isPlaying` true across a file boundary: the item
    /// has played to its end and paused itself while the coordinator opens
    /// the next file. A check there would rebuild at every file end.
    @Test("an item that has played to its end is not a dead start")
    func endedItemIsNotDead() async {
        let player = await loaded()
        player.engineClock = { SilentAudio.duration }
        player.engineTimeControl = { .paused }
        player.play()

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
        #expect(player.isPlaying)
    }

    @Test("a start made while its file is still being placed is the watchdog's, not the check's")
    func placementInFlightIsNotChecked() async {
        let player = AudioPlayer()
        player.watchdogInterval = .seconds(3600)
        player.startCheckDelay = .seconds(3600)
        player.engineTimeControl = { .paused }
        player.whileLoadingAsset = {
            player.play()
            player.checkStart(now: .now + .seconds(1))
        }
        _ = await player.load(url: SilentAudio.url, href: "silence.wav", startAt: Self.place)
        checkAfterStart(player)

        #expect(player.rebuilds == 0)
    }

    @Test("a check armed by an earlier start does nothing after a pause, a new load or an unload")
    func staleChecksAreInert() async {
        let player = await loaded()
        player.engineTimeControl = { .paused }

        player.play()
        player.pause()
        checkAfterStart(player)
        #expect(player.rebuilds == 0, "a check outlived the pause")

        player.play()
        #expect(await player.load(url: SilentAudio.url, href: "silence.wav", startAt: 30) == .loaded)
        checkAfterStart(player)
        #expect(player.rebuilds == 0, "a check outlived the load that replaced its item")

        player.play()
        player.unload()
        checkAfterStart(player)
        #expect(player.rebuilds == 0, "a check outlived the unload")
    }

    @Test("a seek after the start is a new place, not a still clock")
    func seekSinceTheStartIsNotDead() async {
        let player = await loaded()
        player.engineClock = { Self.place }
        player.engineTimeControl = { .playing }
        player.play()
        _ = await player.seek(to: Self.place)

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
    }

    @Test("a streamed start the engine leaves paused is rebuilt too")
    func streamedDeadStart() async {
        let player = await loaded()
        player.currentItemIsFile = false
        player.engineTimeControl = { .paused }
        player.play()

        checkAfterStart(player)
        await rebuilt(player)

        #expect(player.rebuilds == 1)
    }

    @Test("a start paused before its check is not looked at")
    func pausedBeforeTheCheck() async {
        let player = await loaded()
        player.engineTimeControl = { .paused }
        player.play()
        player.pause()

        checkAfterStart(player)

        #expect(player.rebuilds == 0)
        #expect(player.startFailure == nil)
    }

    @Test("each press of play gets its own rebuild")
    func eachPressGetsARetry() async {
        let player = await loaded()
        player.engineTimeControl = { .paused }
        player.play()
        checkAfterStart(player)
        await rebuilt(player)
        checkAfterStart(player)
        #expect(!player.isPlaying)
        #expect(player.startFailure == .audioStopped)

        player.play()
        #expect(player.startFailure == nil, "a play that goes through clears what was said")
        checkAfterStart(player)
        await rebuilt(player)

        #expect(player.rebuilds == 2, "the second press was given no rebuild")
    }

    // MARK: - Stops that used to be silent

    @Test("the watchdog's stop says the audio stopped")
    func watchdogStopIsSaid() async {
        let player = await loaded()
        var told: [AudioPlayer.StartFailure?] = []
        player.onStartFailure = { told.append($0) }
        player.play()
        player.engineClock = { 42 }
        let start = ContinuousClock.now
        player.checkForStall(now: start)
        player.checkForStall(now: start + .seconds(9))
        for _ in 0..<100 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
        player.checkForStall(now: start + .seconds(10))
        player.checkForStall(now: start + .seconds(19))

        #expect(!player.isPlaying)
        #expect(player.startFailure == .audioStopped)
        #expect(told.last == .audioStopped)
    }

    @Test("an item that fails while playing says it would not play")
    func itemFailureIsSaid() async {
        let player = await loaded()
        var told: [AudioPlayer.StartFailure?] = []
        player.onStartFailure = { told.append($0) }
        player.play()

        player.itemDidStop(generation: player.itemGenerationForTests, reason: "test", servicesReset: false)

        #expect(!player.isPlaying)
        #expect(player.startFailure == .wouldNotOpen)
        #expect(told.last == .wouldNotOpen)
        #expect(player.rebuilds == 0, "an ordinary failure is not a reset")
    }

    @Test("a play the session refuses says the audio is busy")
    func sessionRefusalIsSaid() async {
        let player = await loaded()
        player.activateSession = { false }

        player.play()

        #expect(!player.isPlaying)
        #expect(player.startFailure == .audioBusy)
        player.activateSession = { true }
        player.play()
        #expect(player.startFailure == nil)
    }
}
