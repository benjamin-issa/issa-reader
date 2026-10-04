import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// A scrub or a skip lands on the time it names, inside whichever entry holds
/// it — not at the start of that entry.
///
/// The entry's start was all a seek kept. On a v2 book that put a skip at the
/// start of the sentence it fell in, a few seconds early. On a v3 book a hole
/// or an audio chapter is a single entry minutes long, so a scrub inside one
/// went back to its start and a thirty-second skip forward from its middle
/// went backwards; and every such landing was saved as a position the
/// listener had chosen.
///
/// The v3 fixture's entries these lean on, with their place on the book's
/// timeline (`readalong-v3.epub` is laid out in `SMILV3Tests`' header):
///
///      3  ch01-s1                track1   17–24.25   book 17–24.25
///      7  storyteller_audio_1-s0 bonus1   0–180      book 43.999–223.999
///      8  storyteller_audio_1-s0 bonus2   0–150      book 223.999–373.999
///      9  ch02-s0                track2a  0–5        book 373.999–378.999
///     18  ch03-s4  after-hole    track3   25–33      the end of the book
///
/// The player's clock is asserted only straight after the await that set it:
/// the fixture's audio files are placeholders a fraction of a second long,
/// and the periodic observer writes the real, clamped clock over it as soon
/// as the main actor is free. The same observer re-runs the clock on the
/// coordinator, so it is taken away, and so is the end of the file.
@MainActor
@Suite("A scrub or a skip lands where it says, not at the start of the entry")
struct ReadalongSeekOffsetTests {
    static func make(v2: Bool = false) throws -> (ReadalongCoordinator, SMILTimeline, URL) {
        let (subject, timeline, directory) = v2
            ? try ReadalongCoordinatorTests.make() : try ReadalongV3Tests.make()
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        return (subject, timeline, directory)
    }

    /// Where an entry starts on the book's timeline.
    static func bookStart(of entry: SMILEntry) -> TimeInterval {
        entry.cumulativeEnd - entry.duration
    }

    @Test("a scrub into the middle of an audio chapter lands in its middle")
    func scrubIntoALongEntry() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let interlude = timeline.entries[7]
        let target = Self.bookStart(of: interlude) + 60

        await subject.seek(toBookProgress: target / total)
        #expect(abs(subject.player.currentTime - 60) < 0.01, "a minute into bonus1")
        #expect(subject.activeEntry == interlude)
        #expect(subject.player.currentAudioHref == interlude.audioHref)
        #expect(abs(subject.bookProgress * total - target) < 0.01)
    }

    /// The finding: from a minute into the audio chapter, +30 s resolved to
    /// the same entry and moved to its start — backwards — and the next +30
    /// did it again.
    @Test("a skip forward inside an audio chapter goes forward by the skip")
    func skipInsideALongEntry() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let interlude = timeline.entries[7]
        let start = Self.bookStart(of: interlude)

        await subject.seek(toBookProgress: (start + 60) / total)
        await subject.skipBook(by: 30)
        #expect(abs(subject.player.currentTime - 90) < 0.01)
        #expect(abs(subject.bookProgress * total - (start + 90)) < 0.01)

        await subject.skipBook(by: 30)
        #expect(abs(subject.player.currentTime - 120) < 0.01, "and on again, not back")
        #expect(abs(subject.bookProgress * total - (start + 120)) < 0.01)
        #expect(subject.activeEntry == interlude)
    }

    /// Back across a file boundary into the audio chapter's second file:
    /// exactly fifteen seconds back, which is 137 s into bonus2.
    @Test("a skip back across a file lands at the time it names in the file before")
    func skipBackAcrossAFile() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let entries = timeline.entries
        let chapterTwo = entries[9], interludeContinued = entries[8]

        #expect(await subject.prepare(at: chapterTwo))
        await subject.player.seek(to: 2)
        await subject.skipBook(by: -15)
        #expect(abs(subject.player.currentTime - 137) < 0.01)
        #expect(subject.activeEntry == interludeContinued)
        #expect(subject.player.currentAudioHref == interludeContinued.audioHref)
        #expect(abs(subject.bookProgress * total - (Self.bookStart(of: chapterTwo) + 2 - 15)) < 0.01)
    }

    /// A pin: a time exactly on a boundary belongs to the entry that starts
    /// there, and lands on its start, as it always did.
    @Test("a scrub exactly onto an entry's start lands on that start")
    func scrubOntoABoundary() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let sentence = timeline.entries[3]
        let boundary = Self.bookStart(of: sentence)
        // The fraction whose time is the boundary itself, not a rounding of
        // it a hair early.
        var progress = boundary / total
        while total * progress < boundary { progress = progress.nextUp }

        await subject.seek(toBookProgress: progress)
        #expect(subject.player.currentTime == sentence.start)
        #expect(subject.activeEntry == sentence)
    }

    /// The far end of the bar is the end of the last entry, short of it by a
    /// hair so that the file still plays out and ends the book.
    @Test("a scrub to the very end lands at the end of the last entry")
    func scrubToTheEnd() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let last = try #require(timeline.entries.last)

        await subject.seek(toBookProgress: 1)
        let landed = subject.player.currentTime
        #expect(abs(landed - (last.end - ReadalongCoordinator.endOfEntryMargin)) < 0.001)
        #expect(landed < last.end)
        #expect(subject.activeEntry == last)
        #expect(subject.bookProgress > 0.999 && subject.bookProgress < 1)
    }

    /// v2 was wrong here too, by a few seconds: a skip landed at the start of
    /// the sentence it fell in. Now a scrub to a time reads back as that time,
    /// as the audiobook engine's does.
    @Test("on a v2 book a scrub reads back as the time it named", arguments: [0, 5.0, 15.3, -1])
    func v2RoundTrip(_ target: TimeInterval) async throws {
        let (subject, timeline, directory) = try Self.make(v2: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let time = target < 0 ? total + target : target

        await subject.seek(toBookProgress: time / total)
        let entry = try #require(subject.activeEntry)
        #expect(abs(subject.player.currentTime - (entry.start + time - Self.bookStart(of: entry))) < 0.01)
        #expect(abs(subject.bookProgress * total - time) < 0.01)
    }

    @Test("on a v2 book a skip back moves by exactly the skip")
    func v2SkipBack() async throws {
        let (subject, timeline, directory) = try Self.make(v2: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let total = timeline.totalDuration
        let first = timeline.entries[0]

        await subject.seek(toBookProgress: 15.3 / total)
        await subject.skipBook(by: -15)
        #expect(abs(subject.player.currentTime - (first.start + 0.3)) < 0.01)
        #expect(subject.activeEntry == first)
        #expect(abs(subject.bookProgress * total - 0.3) < 0.01)
    }
}
