import AVFoundation
import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// A file that would not open is not something to press play over.
///
/// `load` already stopped the player the first time a file failed, and said
/// `.failed`. Everything after that went on as if it had not: the player kept
/// the dead item and its href, `play()` never looked, and the next press — a
/// second tap of the button, a tap on another sentence in the same file, a
/// play command from the lock screen or the car — took the audio session,
/// stopped whatever the listener had been hearing, and drew a pause glyph over
/// silence that nothing ever stood down.
@Suite("A file that would not open")
@MainActor
struct DeadItemTests {
    /// A file AVFoundation cannot open, at a path the test can later fill.
    static func missing(_ ext: String = "wav") -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-dead-item-\(UUID().uuidString).\(ext)")
    }

    // MARK: - The player

    /// R-10. The press after the failure, which used to be the one that
    /// claimed playback.
    @Test("play over a failed item claims nothing")
    func playOverAFailedItemClaimsNothing() async {
        let player = AudioPlayer()
        let owner = RateLog()
        player.setRateObserver(for: owner) { owner.rates.append($0) }

        let outcome = await player.load(url: Self.missing(), href: "dead.wav")
        try? #require(outcome == .failed)
        owner.rates.removeAll()

        player.play()

        #expect(player.isPlaying == false, "a player holding a dead item said it was playing")
        #expect(player.engineRate == 0)
        #expect(owner.rates.allSatisfy { $0 == 0 }, "the lock screen and the app were told it started: \(owner.rates)")
        #expect(player.currentAudioHref == nil, "the dead file is still named as the one loaded")
        #expect(player.itemHasFailed)
    }

    /// The other half of "nothing is claimed": the next load is a fresh item,
    /// and plays.
    @Test("a load after a failure plays again")
    func aLoadAfterAFailurePlays() async {
        let player = AudioPlayer()
        #expect(await player.load(url: Self.missing(), href: "dead.wav") == .failed)

        #expect(await player.load(url: SilentAudio.url, href: "silence.wav") == .loaded)
        player.play()

        #expect(player.isPlaying)
        #expect(!player.itemHasFailed)
        #expect(player.currentAudioHref == "silence.wav")
    }

    /// R-48. The item fails while the load's own trailing seek is still to
    /// land. `itemDidFail` stood the player down, but the seek still owned the
    /// playhead and came back true, so the load reported `.loaded` for a dead
    /// item and its caller pressed play over it.
    @Test("an item that fails while its load is placing it is reported as failed")
    func aFailureDuringTheTrailingSeek() async {
        let player = AudioPlayer()
        player.beforeTrailingSeek = {
            player.itemDidFail(generation: player.itemGenerationForTests, reason: "test")
        }

        let outcome = await player.load(url: SilentAudio.url, href: "silence.wav", startAt: 30)

        #expect(outcome == .failed, "a load whose item failed under its seek said \(outcome)")
        player.play()
        #expect(player.isPlaying == false)
    }

    // MARK: - The read-along

    /// Two sentences in one file that will not open.
    static func readalong(file: URL) -> (ReadalongCoordinator, SMILTimeline) {
        let chapter = "OEBPS/ch1.xhtml", audio = "OEBPS/Audio/a.wav"
        let timeline = SMILTimeline(entries: [
            SMILEntry(fragmentID: "s1", textHref: chapter, audioHref: audio,
                      start: 0, end: 5, cumulativeEnd: 5),
            SMILEntry(fragmentID: "s2", textHref: chapter, audioHref: audio,
                      start: 5, end: 10, cumulativeEnd: 10),
        ])
        return (ReadalongCoordinator(timeline: timeline, audioFiles: [audio: file]), timeline)
    }

    /// R-10, as the reader meets it: the first press fails honestly; the
    /// second press, and a tap on the next sentence of the same file, used to
    /// take the same-file branch — seek a dead item, say it landed, and play.
    @Test("a read-along whose file would not open does not play on the next press, or the next sentence")
    func aReadalongDoesNotPlayOverADeadFile() async {
        let file = Self.missing()
        let (subject, timeline) = Self.readalong(file: file)
        let first = timeline.entries[0], second = timeline.entries[1]

        #expect(await subject.play(from: first) == false)
        await subject.perform(.playPause, using: CommandMap())
        #expect(subject.player.isPlaying == false, "the second press played over a dead file")

        #expect(await subject.play(from: second) == false, "a sentence in the dead file said it played")
        #expect(subject.player.isPlaying == false)

        await subject.perform(.play, using: CommandMap())
        #expect(subject.player.isPlaying == false, "the lock screen's play played over a dead file")
    }

    /// A press on a dead item is a retry, not a no-op: the file is opened
    /// again, so narration whose file has come back plays.
    @Test("a press after the file has come back plays it")
    func aPressRetriesTheFile() async throws {
        let file = Self.missing()
        defer { try? FileManager.default.removeItem(at: file) }
        let (subject, timeline) = Self.readalong(file: file)
        #expect(await subject.play(from: timeline.entries[0]) == false)

        try FileManager.default.copyItem(at: SilentAudio.url, to: file)
        await subject.perform(.playPause, using: CommandMap())

        #expect(subject.player.isPlaying)
        #expect(!subject.player.itemHasFailed, "it played over the dead item rather than reopening the file")
        #expect(subject.player.currentAudioHref == timeline.entries[0].audioHref)
        #expect(subject.activeEntry == timeline.entries[0])
    }

    // MARK: - The audiobook

    static func manifest() -> AudiobookManifest {
        AudiobookManifest(
            metadata: .init(title: ["und": "Two Tracks"]),
            readingOrder: [
                .init(href: "track0.wav", type: "audio/wav", duration: 600),
                .init(href: "track1.wav", type: "audio/wav", duration: 600),
            ])
    }

    /// R-49. Chapter one is playing; the chapter-two track will not open. The
    /// coordinator had already moved its track, clock and chapter onto chapter
    /// two, and nothing put them back — so Now Playing and CarPlay named a
    /// chapter with no audio, and the writer persisted it with an anchor into a
    /// file that never loaded.
    @Test("a track that will not open leaves the book where it was")
    func aDeadTrackLeavesTheBookWhereItWas() async {
        let subject = AudiobookCoordinator(
            manifest: Self.manifest(),
            source: .files(["track0.wav": SilentAudio.url, "track1.wav": Self.missing()]))
        #expect(await subject.start(atProgress: 0.1) == .landed)
        let before = (subject.trackIndex, subject.bookTime, subject.chapterIndex)
        try? #require(before.0 == 0)

        await subject.play(chapter: 1)

        #expect(subject.trackIndex == before.0, "the track moved onto a file that never opened")
        #expect(subject.chapterIndex == before.2, "the chapter moved onto audio that never loaded")
        #expect(abs(subject.bookTime - before.1) < 0.001, "the clock moved to \(subject.bookTime)")
        #expect(subject.currentAnchor == nil, "an anchor names a file that never loaded")
        #expect(subject.player.isPlaying == false)

        // And a press from here reloads the place the book is, rather than
        // claiming playback over nothing.
        await subject.perform(.play, using: CommandMap())
        #expect(subject.player.isPlaying)
        #expect(subject.player.currentAudioHref == "track0.wav")
        #expect(subject.trackIndex == 0)
    }

    /// R-11's half in this package: a start whose first track will not open
    /// says so, rather than returning as if it had begun.
    @Test("a start whose track will not open reports it")
    func aStartOverADeadTrackReportsIt() async {
        let subject = AudiobookCoordinator(
            manifest: Self.manifest(),
            source: .files(["track0.wav": Self.missing(), "track1.wav": SilentAudio.url]))

        #expect(await subject.start(atProgress: 0) == .unplayable)
        #expect(subject.player.isPlaying == false)
        #expect(subject.player.currentAudioHref == nil)
        #expect(await subject.start(atProgress: .nan) == .unplayable, "no place is not a start")
    }
}

/// What the rate observers were told, in order.
@MainActor
private final class RateLog {
    var rates: [Float] = []
}
