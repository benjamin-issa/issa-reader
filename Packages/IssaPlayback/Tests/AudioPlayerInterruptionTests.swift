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
}
