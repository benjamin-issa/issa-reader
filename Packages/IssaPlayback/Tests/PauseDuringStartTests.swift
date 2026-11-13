import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// A pause that arrives while a start is still opening its file is the
/// listener's last word, and the start must not undo it.
///
/// `AudioPlayer.pause()` bumps no generation and `load` leaves `isPlaying`
/// alone, so a start that awaited a load or a seek and then called `play()`
/// started the audio again over a headphone click, a lock-screen pause or a
/// sleep timer that had landed in the window.
@MainActor
@Suite("A pause that lands while a start is opening its file")
struct PauseDuringStartTests {
    @Test("a read-along start does not play over it")
    func readalongStart() async throws {
        let (subject, timeline, directory) = try ReadalongClearTests.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        let entry = timeline.entries[3]
        // Playing, as a listener tapping a sentence in a file not yet loaded is.
        subject.player.play()
        subject.player.whileLoadingAsset = { subject.player.pause() }

        let moved = await subject.play(from: entry)

        #expect(moved, "the move itself happened")
        #expect(subject.activeEntry == entry)
        #expect(!subject.player.isPlaying, "the start undid the pause that landed while it opened its file")
        #expect(subject.player.engineRate == 0)
    }

    @Test("a read-along start with no pause still plays")
    func readalongStartPlays() async throws {
        let (subject, timeline, directory) = try ReadalongClearTests.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil

        #expect(await subject.play(from: timeline.entries[3]))

        #expect(subject.player.isPlaying)
    }

    private static func audiobook() -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: DeadItemTests.manifest(),
            source: .files(["track0.wav": SilentAudio.url, "track1.wav": SilentAudio.url]))
    }

    @Test("an audiobook chapter start does not play over it")
    func chapterStart() async {
        let subject = Self.audiobook()
        #expect(await subject.start(atProgress: 0.1) == .landed)
        subject.player.whileLoadingAsset = { subject.player.pause() }

        await subject.play(chapter: 1)

        #expect(!subject.player.isPlaying, "the chapter start undid the pause")
    }

    @Test("an audiobook start does not play over it")
    func bookStart() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = { subject.player.pause() }

        #expect(await subject.start(atProgress: 0.1) == .landed)

        #expect(!subject.player.isPlaying, "the start undid the pause")
    }

    @Test("an audiobook chapter start with no pause still plays")
    func chapterStartPlays() async {
        let subject = Self.audiobook()
        #expect(await subject.start(atProgress: 0.1) == .landed)

        await subject.play(chapter: 1)

        #expect(subject.player.isPlaying)
    }
}
