import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// Reading a place off the coordinator without going there, and putting the
/// narration back to where it was before anything played.
///
/// The player sheet opened on a read-along nobody has started drew the start
/// of the book, because the coordinator is built on open and holds nothing.
/// `readout(at:)` is how the reader asks what the numbers would be with the
/// voice on a sentence, and `clearPosition()` is how it gets back to the state
/// where that question is the right one to ask.
///
/// Both fixtures are used, for the shapes they add: the v3 book's holes and
/// audio chapters are entries whose start is not a sentence's.
@MainActor
@Suite("Reading a place without going there, and giving it back")
struct ReadalongClearTests {
    static func make(v2: Bool) throws -> (ReadalongCoordinator, SMILTimeline, URL) {
        v2 ? try ReadalongCoordinatorTests.make() : try ReadalongV3Tests.make()
    }

    // MARK: - readout(at:)

    /// The point of `readout(at:)`: the sheet draws these numbers before Play,
    /// and the coordinator publishes its own the moment Play puts the voice
    /// there. They are one computation, so they are equal to the last bit and
    /// the thumb does not move when Play is pressed.
    @Test("what the readout says is what the move then publishes", arguments: [true, false])
    func readoutIsWhatAMovePublishes(v2: Bool) async throws {
        let (subject, timeline, directory) = try Self.make(v2: v2)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The clock off the player, so nothing but the move writes the numbers.
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil

        for entry in timeline.entries {
            let predicted = subject.readout(at: entry)

            #expect(await subject.prepare(at: entry), "\(entry.fragmentID) did not load")

            #expect(abs(predicted.bookProgress - subject.bookProgress) < 1e-9,
                    "\(entry.fragmentID): \(predicted.bookProgress) said, \(subject.bookProgress) published")
            let published = subject.chapterSpan
            #expect(predicted.chapterSpan?.start == published?.start,
                    "\(entry.fragmentID): the chapter begins elsewhere")
            #expect(predicted.chapterSpan?.duration == published?.duration,
                    "\(entry.fragmentID): the chapter runs for a different time")
            #expect(published != nil, "\(entry.fragmentID) is in a chapter the bar can describe")
        }
    }

    /// Display only. A readout that moved anything would be the cue the design
    /// rejected: it leaves a sentence behind, and Play resumes pages back.
    @Test("reading a place off leaves the coordinator where it was")
    func readoutMovesNothing() async throws {
        let (subject, timeline, directory) = try Self.make(v2: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = try #require(timeline.entries.dropFirst().first)
        var fragments = 0, chapters = 0, seeks = 0
        subject.onFragmentChange = { _ in fragments += 1 }
        subject.onChapterChange = { _ in chapters += 1 }
        subject.onSeek = { seeks += 1 }

        let readout = subject.readout(at: entry)

        #expect(readout.bookProgress > 0, "a sentence past the first has somewhere to be")
        #expect(subject.activeEntry == nil)
        #expect(subject.activeFragmentID == nil)
        #expect(subject.bookProgress == 0)
        #expect(subject.chapterSpan == nil)
        #expect(subject.player.currentAudioHref == nil, "nothing was loaded to read it")
        #expect(!subject.player.isPlaying)
        #expect(fragments + chapters + seeks == 0, "nobody was told anything moved")
    }

    // MARK: - clearPosition()

    @Test("clearing leaves nothing lit, nothing playing and nothing loaded", arguments: [true, false])
    func clearLeavesNothing(v2: Bool) async throws {
        let (subject, timeline, directory) = try Self.make(v2: v2)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        let entry = try #require(timeline.entries.dropFirst().first)
        #expect(await subject.play(from: entry))
        try #require(subject.activeEntry == entry && subject.player.isPlaying)
        try #require(subject.player.currentAudioHref == entry.audioHref)

        subject.clearPosition()

        #expect(subject.activeEntry == nil)
        #expect(subject.activeFragmentID == nil)
        #expect(subject.bookProgress == 0)
        #expect(subject.chapterSpan == nil)
        #expect(subject.currentAnchor == nil, "no place left for the next save to record")
        #expect(!subject.player.isPlaying)
        #expect(subject.player.currentAudioHref == nil, "the file is unloaded, not just forgotten")
        #expect(subject.player.duration == 0)
        #expect(subject.player.currentTime == 0)
        #expect(subject.player.engineTime.isNaN, "and the engine holds no item")
        #expect(subject.player.engineRate == 0)
    }

    /// The reason the file has to go with the entry. The player's periodic
    /// observer fires on a pause and on a seek, and `advance(to:)` re-derives
    /// the sentence from whichever file the player still names.
    @Test("a clock tick after clearing does not bring the sentence back")
    func aTickAfterClearingDoesNotResurrect() async throws {
        let (subject, timeline, directory) = try Self.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entry = timeline.entries[3]
        #expect(await subject.play(from: entry))
        // Taken, and the real clock with it, so the one tick below is the only
        // one there is.
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        var fragments = 0
        subject.onFragmentChange = { _ in fragments += 1 }

        subject.clearPosition()
        tick(entry.start + 0.01)

        #expect(subject.activeEntry == nil)
        #expect(subject.activeFragmentID == nil)
        #expect(subject.bookProgress == 0)
        #expect(fragments == 0, "and the page was not told to light a sentence")
    }

    /// The end of a file queued just before the clear. Read as the end of the
    /// book it would give the audio route away, which a stop does not mean to.
    @Test("a file ending after clearing is not the end of the book")
    func aFileEndingAfterClearingIsNotTheEndOfTheBook() async throws {
        let (subject, timeline, directory) = try Self.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await subject.prepare(at: timeline.entries[3]))
        subject.player.onTimeUpdate = nil
        let ended = try #require(subject.player.onFinishedFile)

        subject.clearPosition()
        ended()
        // The ending hops through a Task before it is answered.
        try await Task.sleep(for: .milliseconds(200))

        #expect(subject.player.sessionsEnded == 0, "the audio route was given back")
        #expect(subject.activeEntry == nil)
    }

    @Test("playing after clearing opens the file again")
    func playingAfterClearingReloads() async throws {
        let (subject, timeline, directory) = try Self.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        let entry = timeline.entries[3]
        #expect(await subject.play(from: entry))
        subject.clearPosition()

        // The same sentence of the same file, which is the case where a player
        // that still named its file would seek in an item that is not there.
        #expect(await subject.play(from: entry))

        #expect(subject.activeEntry == entry)
        #expect(subject.activeFragmentID == entry.fragmentID)
        #expect(subject.player.currentAudioHref == entry.audioHref)
        #expect(subject.player.isPlaying)
        #expect(subject.player.engineTime.isFinite, "an item is in the engine again")
    }

    /// A start still opening its file when the clear lands. The move is
    /// overtaken: finishing it would put the position back, and `play(from:)`
    /// would press play over a player with nothing in it.
    @Test("a clear that lands while a move is opening its file is not undone by it")
    func aClearDuringAMoveSticks() async throws {
        let (subject, timeline, directory) = try Self.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        let entry = timeline.entries[3]
        subject.player.whileLoadingAsset = { subject.clearPosition() }

        let played = await subject.play(from: entry)

        #expect(!played, "the move was overtaken")
        #expect(!subject.player.isPlaying, "and nothing was pressed to play")
        #expect(subject.activeEntry == nil)
        #expect(subject.activeFragmentID == nil)
        #expect(subject.bookProgress == 0)
        #expect(subject.player.currentAudioHref == nil)
        #expect(subject.player.duration == 0, "the file that was opening is nobody's")
        #expect(subject.movesInFlight == 0)

        // And the start after the stop is a start, not the one it overtook.
        #expect(await subject.play(from: entry))
        #expect(subject.activeEntry == entry)
        #expect(subject.player.isPlaying)
    }

    /// The same overtaking for a seek in a file the player already holds, which
    /// is the other branch of `move(to:)`.
    @Test("a clear that lands while a move is seeking in its file is not undone by it")
    func aClearDuringASeekSticks() async throws {
        let (subject, timeline, directory) = try Self.make(v2: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil
        let first = timeline.entries[3]
        let sameFile = try #require(
            timeline.entries.first { $0.audioHref == first.audioHref && $0 != first })
        #expect(await subject.prepare(at: first))
        let seeking = Task { await subject.play(from: sameFile) }

        // The seek is awaiting the engine; this runs before it returns.
        await Task.yield()
        subject.clearPosition()
        let played = await seeking.value

        #expect(!played)
        #expect(!subject.player.isPlaying)
        #expect(subject.activeEntry == nil)
    }
}
