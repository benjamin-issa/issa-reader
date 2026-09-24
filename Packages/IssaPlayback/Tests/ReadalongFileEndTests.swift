import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// The end of an audio file whose clips the CTC aligner left out of time
/// order, played by the coordinator over the v3 fixture's own files.
///
/// The clip playing when such a file runs out is the one that ends last, and
/// it need not be the file's last entry. The advance asked for the entry after
/// it, got another clip of the same file, seeked back into the file, and the
/// file ended on the same clip again — for ever, and without a chapter ever
/// ending, so an end-of-chapter sleep timer never paused it.
@MainActor
@Suite("The read-along leaves a file whose clips are out of order at its end")
struct ReadalongFileEndTests {
    typealias Shapes = ReadalongV3ShapesTests
    static let chapterThree = "OEBPS/ch03.xhtml", track3 = "OEBPS/Audio/track3.mp3"

    /// The last two rows of each shape below: the next two files.
    static let nextFiles: [(fragment: String, text: String, audio: String,
                            start: TimeInterval, end: TimeInterval, audioOnly: Bool)] = [
        ("ch02-s0", Shapes.chapterTwo, Shapes.track2, 0, 5, false),
        ("ch03-s0", chapterThree, track3, 0, 4, false),
    ]

    /// Takes the clock off the player and counts chapter endings, the way the
    /// shapes tests do, so the test says exactly where the audio is.
    static func take(
        _ subject: ReadalongCoordinator,
    ) throws -> (tick: (TimeInterval) -> Void, endings: () -> Int) {
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        let counter = Counter()
        subject.onChapterChangeObserved = { counter.value += 1 }
        return (tick, { counter.value })
    }

    ///      0  ch01-s0  track1   0–5
    ///      1  ch01-s1  track1   10–44   heard last, runs to the end of the file
    ///      2  ch01-s2  track1   5–10    listed last
    ///      3  ch02-s0  track2a  0–5
    ///      4  ch03-s0  track3   0–4
    @Test("the end of a file whose last-heard clip is not its last entry moves on to the next file")
    func outOfOrderFileEnds() async throws {
        let timeline = Shapes.narration([
            ("ch01-s0", Shapes.chapterOne, Shapes.track1, 0, 5, false),
            ("ch01-s1", Shapes.chapterOne, Shapes.track1, 10, 44, false),
            ("ch01-s2", Shapes.chapterOne, Shapes.track1, 5, 10, false),
        ] + Self.nextFiles)
        let (subject, directory) = try Shapes.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        // Prepared rather than played, so no real end of file joins in.
        #expect(await subject.prepare(at: entries[0]))
        let (tick, endings) = try Self.take(subject)
        tick(40)
        #expect(subject.activeEntry == entries[1])

        subject.player.onFinishedFile?()
        let advanced = await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[3] && subject.movesInFlight == 0
        }
        #expect(advanced, "the end of the file went back into the same file")
        #expect(subject.activeEntry == entries[3])
        #expect(subject.player.currentAudioHref == Shapes.track2)
        #expect(endings() == 1, "chapter one ended, once")
    }

    ///      0  ch01-s0             track1   0–5
    ///      1  ch01-s0  hole       track1   5–21    over the next two, to the end
    ///      2  ch01-s1             track1   10–15
    ///      3  ch01-s2             track1   15–20
    ///      4  ch02-s0             track2a  0–5
    ///      5  ch03-s0             track3   0–4
    @Test("the end of a file whose hole spans its last clips moves on to the next file")
    func holeOverTheLastClipsEnds() async throws {
        let timeline = Shapes.narration([
            ("ch01-s0", Shapes.chapterOne, Shapes.track1, 0, 5, false),
            ("ch01-s0", Shapes.chapterOne, Shapes.track1, 5, 21, true),
            ("ch01-s1", Shapes.chapterOne, Shapes.track1, 10, 15, false),
            ("ch01-s2", Shapes.chapterOne, Shapes.track1, 15, 20, false),
        ] + Self.nextFiles)
        let (subject, directory) = try Shapes.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        #expect(await subject.prepare(at: entries[0]))
        let (tick, endings) = try Self.take(subject)
        tick(20.5)
        #expect(subject.activeEntry == entries[1], "only the hole is still playing at 20.5 s")

        subject.player.onFinishedFile?()
        let advanced = await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[4] && subject.movesInFlight == 0
        }
        #expect(advanced, "the end of the file went back into the same file")
        #expect(subject.player.currentAudioHref == Shapes.track2)
        #expect(endings() == 1)
    }

    /// The end of track1 reaches the coordinator just as the listener moves to
    /// chapter two, and the advance it schedules runs at the move's first
    /// suspension, with `activeEntry` already on chapter two. Answered, it
    /// advanced from there — past the rest of chapter two, into chapter three,
    /// and reported chapter two as ended.
    @Test("an ending that arrives while the listener is moving elsewhere is not acted on")
    func aStaleEndingIsDropped() async throws {
        let timeline = Shapes.narration([
            ("ch01-s0", Shapes.chapterOne, Shapes.track1, 0, 5, false),
            ("ch01-s1", Shapes.chapterOne, Shapes.track1, 5, 44, false),
        ] + Self.nextFiles)
        let (subject, directory) = try Shapes.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        #expect(await subject.prepare(at: entries[0]))
        let (_, endings) = try Self.take(subject)

        // Queued on the main actor before the move begins, so it runs at the
        // move's own suspension inside AVFoundation.
        subject.player.onFinishedFile?()
        #expect(await subject.prepare(at: entries[2]))
        #expect(await ReadalongV3Tests.waitUntil { subject.movesInFlight == 0 })

        #expect(subject.activeEntry == entries[2], "the move the listener made is where the book is")
        #expect(subject.player.currentAudioHref == Shapes.track2)
        #expect(endings() == 0, "a chapter the listener moved into did not end")
    }
}

/// A count a closure can bump, for the chapter endings above.
@MainActor
private final class Counter {
    var value = 0
}
