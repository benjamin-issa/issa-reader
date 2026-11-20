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

    /// An interruption is the system's pause, not the listener's: the start
    /// that was opening its file when it began must not read it as a last word
    /// and drop the book, and the end of the interruption must find it ready
    /// to resume.
    @Test("an interruption that lands while an audiobook start opens its file resumes at its end")
    func interruptionDuringBookStart() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }

        #expect(await subject.start(atProgress: 0.1) == .landed)
        #expect(!subject.player.isPlaying, "the book played over the interruption")

        subject.player.interruptionEnded(shouldResume: true)

        #expect(subject.player.isPlaying, "the interruption took a start that was on its way to playing")
    }

    @Test("an interruption that lands while a chapter start opens its file resumes at its end")
    func interruptionDuringChapterStart() async {
        let subject = Self.audiobook()
        #expect(await subject.start(atProgress: 0.1) == .landed)
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }

        await subject.play(chapter: 1)
        #expect(!subject.player.isPlaying)

        subject.player.interruptionEnded(shouldResume: true)

        #expect(subject.player.isPlaying)
    }

    @Test("a read-along start under an interruption resumes at its end")
    func interruptionDuringReadalongStart() async throws {
        let (subject, timeline, directory) = try ReadalongClearTests.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }

        #expect(await subject.play(from: timeline.entries[3]))
        #expect(!subject.player.isPlaying, "the narration played over the interruption")

        subject.player.interruptionEnded(shouldResume: true)

        #expect(subject.player.isPlaying)
    }

    /// The listener's pause is still the last word, even when it lands inside
    /// an interruption the start was waiting out.
    @Test("a pause during the interruption still wins over the start's intent")
    func pauseDuringInterruptedStart() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }
        #expect(await subject.start(atProgress: 0.1) == .landed)

        subject.player.pause()
        subject.player.interruptionEnded(shouldResume: true)

        #expect(!subject.player.isPlaying, "the end of the interruption undid the listener's pause")
    }

    @Test("an interruption that ends without asking to resume leaves the start's intent unmet")
    func interruptionEndedWithoutResume() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }
        #expect(await subject.start(atProgress: 0.1) == .landed)

        subject.player.interruptionEnded(shouldResume: false)

        #expect(!subject.player.isPlaying)
    }

    // MARK: - A start whose load spans a whole interruption

    @Test("a real audiobook start over an interruption that is still going does not play, and its end resumes it")
    func bookStartOverAnInterruptionStillGoing() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }

        #expect(await subject.start(atProgress: 0.1) == .landed)

        #expect(!subject.player.isPlaying, "the start played over the interruption")
        subject.player.interruptionEnded(shouldResume: true)
        #expect(subject.player.isPlaying)
    }

    @Test("a real audiobook start over an interruption that ended with a resume plays")
    func bookStartOverAnInterruptionEndedWithResume() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = {
            subject.player.interruptionBegan()
            subject.player.interruptionEnded(shouldResume: true)
        }

        #expect(await subject.start(atProgress: 0.1) == .landed)

        #expect(subject.player.isPlaying)
    }

    @Test("a real audiobook start over an interruption that ended without a resume does not play")
    func bookStartOverAnInterruptionEndedWithoutResume() async {
        let subject = Self.audiobook()
        subject.player.whileLoadingAsset = {
            subject.player.interruptionBegan()
            subject.player.interruptionEnded(shouldResume: false)
        }

        #expect(await subject.start(atProgress: 0.1) == .landed)

        #expect(!subject.player.isPlaying)
    }

    @Test("a real chapter start and a real read-along start follow the same rule")
    func otherStartsOverAnInterruption() async throws {
        let subject = Self.audiobook()
        #expect(await subject.start(atProgress: 0.1) == .landed)
        subject.player.pause()
        subject.player.whileLoadingAsset = { subject.player.interruptionBegan() }
        await subject.play(chapter: 1)
        #expect(!subject.player.isPlaying)
        subject.player.interruptionEnded(shouldResume: true)
        #expect(subject.player.isPlaying)

        let (readalong, timeline, directory) = try ReadalongClearTests.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        readalong.player.onTimeUpdate = nil
        readalong.player.onFinishedFile = nil
        readalong.player.whileLoadingAsset = { readalong.player.interruptionBegan() }
        #expect(await readalong.play(from: timeline.entries[3]))
        #expect(!readalong.player.isPlaying)
        readalong.player.interruptionEnded(shouldResume: true)
        #expect(readalong.player.isPlaying)
    }
}
