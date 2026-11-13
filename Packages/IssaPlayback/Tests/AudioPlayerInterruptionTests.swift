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

    /// A play asked for while the session is the system's cannot be heard, and
    /// is not lost: it is what the interruption's end resumes.
    @Test("a play asked for during an interruption waits for its end")
    func playDuringAnInterruptionWaits() async {
        let player = await playing()
        player.pause()

        player.interruptionBegan()
        player.play()
        #expect(!player.isPlaying, "the book played over the interruption")
        #expect(player.engineRate == 0)

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
