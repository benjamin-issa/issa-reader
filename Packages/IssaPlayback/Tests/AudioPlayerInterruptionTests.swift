import Foundation
import Testing

@testable import IssaPlayback

/// What an interruption remembers about the book it stopped.
@MainActor
@Suite("Interruptions of the audio session")
struct AudioPlayerInterruptionTests {
    private func playing() async -> AudioPlayer {
        let player = AudioPlayer()
        #expect(await player.load(url: SilentAudio.url, href: "silence.wav") == .loaded)
        player.play()
        return player
    }

    @Test("one interruption resumes the book that was playing")
    func oneInterruption() async {
        let player = await playing()

        player.interruptionBegan()
        #expect(!player.isPlaying)
        player.interruptionEnded(shouldResume: true)

        #expect(player.isPlaying)
    }

    /// A second `began` before the first has ended finds the player already
    /// paused, and used to record that as the state to restore.
    @Test("a second interruption before the first ends does not forget the book was playing")
    func secondInterruption() async {
        let player = await playing()

        player.interruptionBegan()
        player.interruptionBegan()
        player.interruptionEnded(shouldResume: true)

        #expect(player.isPlaying, "the book stayed silent after the interruption had ended")
    }

    @Test("a pause during an interruption is still not undone by its end")
    func explicitPauseStands() async {
        let player = await playing()

        player.interruptionBegan()
        player.interruptionBegan()
        player.pause()
        player.interruptionEnded(shouldResume: true)

        #expect(!player.isPlaying)
    }

    @Test("an interruption of a paused book resumes nothing")
    func pausedStaysPaused() async {
        let player = await playing()
        player.pause()

        player.interruptionBegan()
        player.interruptionBegan()
        player.interruptionEnded(shouldResume: true)

        #expect(!player.isPlaying)
    }

    /// The system does not always deliver the `.ended`. A latch that never
    /// lapsed let a much later interruption's end start the book by itself.
    @Test("an end that arrives long after the interruption began resumes nothing")
    func anExpiredLatchResumesNothing() async throws {
        let player = await playing()
        player.interruptionLatchLifetime = .milliseconds(20)

        player.interruptionBegan()
        try await Task.sleep(for: .milliseconds(80))
        player.interruptionEnded(shouldResume: true)

        #expect(!player.isPlaying, "a book the interruption took long ago started by itself")
    }

    @Test("a new interruption long after a lost end does not inherit the old latch")
    func aLostEndDoesNotCarryOver() async throws {
        let player = await playing()
        player.interruptionLatchLifetime = .milliseconds(20)

        player.interruptionBegan()
        try await Task.sleep(for: .milliseconds(80))
        // The first end never came; an unrelated interruption begins and ends.
        player.interruptionBegan()
        player.interruptionEnded(shouldResume: true)

        #expect(!player.isPlaying)
    }

    @Test("an interruption that goes on is still one: the latest began keeps the latch alive")
    func aContinuingInterruptionResumes() async throws {
        let player = await playing()
        // Each wait is well inside the lifetime and the two together are well
        // past it, with room either side for a loaded machine: at 150 ms and
        // two 100 ms waits, a release run's second sleep overran the latch.
        player.interruptionLatchLifetime = .seconds(2)

        player.interruptionBegan()
        try await Task.sleep(for: .milliseconds(1200))
        player.interruptionBegan()
        try await Task.sleep(for: .milliseconds(1200))
        player.interruptionEnded(shouldResume: true)

        #expect(player.isPlaying)
    }

    /// The system's pause is not the listener's: a start comparing
    /// `pauseCount` across its suspension reads a bumped count as the
    /// listener's last word.
    @Test("an interruption is not counted as a pause by the listener")
    func interruptionIsNotTheListenersPause() async {
        let player = await playing()
        let before = player.pauseCount

        player.interruptionBegan()
        #expect(player.pauseCount == before)

        player.pause()
        #expect(player.pauseCount == before &+ 1)
    }

    /// The listener's own Play is never swallowed: the system says nothing when
    /// it gave the session back before the app was running, so there may be no
    /// end to wait for.
    @Test("a play asked for during an interruption plays")
    func playDuringAnInterruptionPlays() async {
        let player = await playing()
        player.pause()

        player.interruptionBegan()
        player.play()

        #expect(player.isPlaying)
        #expect(player.engineRate == player.rate)
    }

    @Test("an interruption that began because the app was suspended holds nothing")
    func suspendedInterruptionIsNotAnInterruption() async {
        let player = await playing()
        player.pause()

        player.interruptionBegan(wasSuspended: true)
        player.play()

        #expect(player.isPlaying, "Play was swallowed after an interruption that has no end")
    }

    @Test("a suspended interruption is not latched: a book that was playing keeps playing")
    func suspendedInterruptionLatchesNothing() async {
        let player = await playing()

        player.interruptionBegan(wasSuspended: true)

        #expect(player.isPlaying)
        player.interruptionEnded(shouldResume: true)
        #expect(player.isPlaying)
    }

    @Test("a pause after a play asked for during an interruption wins")
    func pauseAfterPlayDuringAnInterruption() async {
        let player = await playing()
        player.pause()

        player.interruptionBegan()
        player.play()
        player.pause()
        player.interruptionEnded(shouldResume: true)

        #expect(!player.isPlaying)
    }

    @Test("a pause during an interruption leaves the next play unheld")
    func pauseEndsTheInterruptionState() async {
        let player = await playing()
        player.interruptionBegan()
        player.pause()

        // A start's tail asked later must not read the abandoned interruption
        // as one still going.
        let token = player.beginStart()
        #expect(player.playAfterStart(token))
    }

    @Test("endSession during an interruption leaves Play working")
    func endSessionDuringAnInterruption() async {
        let player = await playing()
        player.interruptionBegan()
        player.endSession()

        player.play()

        #expect(player.isPlaying)
        // And no stale latch: the end of the old interruption starts nothing.
        player.pause()
        player.interruptionEnded(shouldResume: true)
        #expect(!player.isPlaying)
    }

    // MARK: - A start's tail

    @Test("a start whose load spans an interruption still going does not play, and the end resumes it")
    func startSpanningAnInterruptionStillGoing() async {
        let player = await playing()
        player.pause()
        let token = player.beginStart()

        player.interruptionBegan()

        #expect(!player.playAfterStart(token))
        #expect(!player.isPlaying)
        player.interruptionEnded(shouldResume: true)
        #expect(player.isPlaying, "the interruption's end did not resume the start")
    }

    @Test("a start whose load spans an interruption that ended asking for a resume plays")
    func startSpanningAnInterruptionEndedWithResume() async {
        let player = await playing()
        player.pause()
        let token = player.beginStart()

        player.interruptionBegan()
        player.interruptionEnded(shouldResume: true)
        #expect(!player.isPlaying, "nothing was latched, so the end itself resumes nothing")

        #expect(player.playAfterStart(token))
        #expect(player.isPlaying)
    }

    @Test("a start whose load spans an interruption that ended without a resume does not play")
    func startSpanningAnInterruptionEndedWithoutResume() async {
        let player = await playing()
        player.pause()
        let token = player.beginStart()

        player.interruptionBegan()
        player.interruptionEnded(shouldResume: false)

        #expect(!player.playAfterStart(token))
        #expect(!player.isPlaying)
    }

    @Test("a start's tail does not play over a pause by the listener")
    func startAfterAListenersPause() async {
        let player = await playing()
        let token = player.beginStart()
        player.pause()

        #expect(!player.playAfterStart(token))
    }

    @Test("a pause during the interruption wins over the start that was waiting on it")
    func pauseDuringTheInterruptionWins() async {
        let player = await playing()
        player.pause()
        let token = player.beginStart()
        player.interruptionBegan()
        player.pause()

        #expect(!player.playAfterStart(token))
        player.interruptionEnded(shouldResume: true)
        #expect(!player.isPlaying)
    }

    @Test("once the interruption has ended a play plays")
    func playAfterTheInterruptionPlays() async {
        let player = await playing()
        player.interruptionBegan()
        player.interruptionEnded(shouldResume: false)
        #expect(!player.isPlaying)

        player.play()

        #expect(player.isPlaying)
    }
}
