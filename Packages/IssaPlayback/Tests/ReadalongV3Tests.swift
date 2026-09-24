import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// The read-along coordinator on a v3-aligned book.
///
/// `readalong-v3.epub` is laid out in `SMILV3Tests`' header; the entries
/// these tests lean on are:
///
///      1  ch01-s0                track1   6.5–10.75
///      2  ch01-s0  after-hole    track1   10.75–17
///      3  ch01-s1                track1   17–24.25
///      5  ch01-s5                track1   30.65–35.75
///      6  ch01-s5  after-hole    track1   35.75–44      the end of track1
///      7  storyteller_audio_1-s0 bonus1   0–180         audio chapter, -a0
///      8  storyteller_audio_1-s0 bonus2   0–150         audio chapter, -a1
///      9  ch02-s0                track2a  0–5
///     11  ch02-s1  -a1           track2b  0–3.5
///     17  ch03-s4                track3   21–25
///     18  ch03-s4  after-hole    track3   25–33         the end of the book
@MainActor
@Suite("The read-along on a v3-aligned book")
struct ReadalongV3Tests {
    static func timeline() throws -> (SMILTimeline, EPUBPackage) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong-v3", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        return (SMILParser.timeline(for: package), package)
    }

    /// The v3 fixture with its narration genuinely extracted, exactly as
    /// `ReadalongCoordinatorTests.make` builds the v2 one.
    static func make() throws -> (ReadalongCoordinator, SMILTimeline, URL) {
        let (timeline, package) = try timeline()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-readalong-v3-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "readalong-v3-test", into: directory,
        )
        return (ReadalongCoordinator(timeline: timeline, audioFiles: files), timeline, directory)
    }

    /// Polls until `condition` holds or ten seconds pass. The end-of-file
    /// advance hops through a Task and then awaits a real asset load, which
    /// `ReadalongCoordinatorTests` found can outlast a second under a parallel
    /// run; the caller asserts on the outcome, so a timeout reads as one.
    static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// The loop. Chapter one's file ends in ch01-s5's after-hole, which names
    /// ch01-s5's fragment. The clock ran into the hole without moving
    /// `activeEntry` off the sentence, the end of the file then asked for the
    /// entry after the sentence — the hole — and replayed it; the next end
    /// resolved the hole back to the sentence and found the hole again, for
    /// ever. What follows the hole is the audio chapter, in the next file.
    @Test("a file that ends in an after-hole advances into the audio chapter, not back into the hole")
    func aFileEndingInAHoleAdvances() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries
        let sentence = entries[5], hole = entries[6]
        let interlude = entries[7], interludeContinued = entries[8], chapterTwo = entries[9]
        try #require(hole.isAudioOnly && hole.fragmentID == sentence.fragmentID)
        try #require(interlude.audioHref == "OEBPS/Audio/bonus1.mp3")

        // Prepared rather than played, so nothing runs on after the advance
        // and no real end-of-file notification can join in: `isPlaying` stays
        // false, and the advance moves without resuming.
        #expect(await subject.prepare(at: sentence))
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        var endings = 0
        subject.onChapterChangeObserved = { endings += 1 }

        // The clock runs on from the sentence into the hole that ends the file.
        tick((hole.start + hole.end) / 2)
        #expect(subject.activeEntry == hole)

        subject.player.onFinishedFile?()
        let advanced = await Self.waitUntil {
            subject.activeEntry == interlude && subject.movesInFlight == 0
        }
        #expect(advanced, "the end of the file did not move on to the audio chapter")
        #expect(subject.activeEntry == interlude, "and it must not replay the hole")
        #expect(subject.player.currentAudioHref == interlude.audioHref)
        #expect(endings == 1, "chapter one ended, once")

        // And on through the audio chapter's second file, which is no new
        // chapter, and out into chapter two, which is.
        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil {
            subject.activeEntry == interludeContinued && subject.movesInFlight == 0
        })
        #expect(subject.player.currentAudioHref == interludeContinued.audioHref)
        #expect(endings == 1, "the audio chapter's own second file is not a chapter ending")

        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil { endings == 2 })
        #expect(subject.activeEntry == chapterTwo)
    }

    /// v2 paused at the end of the book, with those seconds folded into the
    /// last sentence. The hole that holds them now must end the same way.
    @Test("the book's closing after-hole ends in a pause")
    func theClosingHolePauses() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries
        let last = entries[17], hole = entries[18]
        try #require(hole == entries.last && hole.isAudioOnly)

        await subject.play(from: last)
        // Silenced and frozen, not paused: `isPlaying` is what is under test.
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        subject.player.rate = 0
        try #require(subject.player.isPlaying)

        tick((hole.start + hole.end) / 2)
        #expect(subject.activeEntry == hole)

        subject.player.onFinishedFile?()
        #expect(await Self.waitUntil { !subject.player.isPlaying }, "the end of the book did not pause")
        #expect(subject.activeEntry == hole, "and nothing replayed")
    }

    /// The hole names the sentence it follows, and v2 lit that sentence for
    /// these same seconds. So the entry moves — the anchor and the skip
    /// buttons measure from it — and the page does not hear about it.
    @Test("the clock running into an after-hole moves the entry and nothing on the page")
    func tickingIntoAnAfterHole() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries
        let sentence = entries[1], hole = entries[2], next = entries[3]

        #expect(await subject.prepare(at: sentence))
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        var fragments: [String] = []
        var chapters: [String] = []
        var endings = 0
        subject.onFragmentChange = { fragments.append($0) }
        subject.onChapterChange = { chapters.append($0) }
        subject.onChapterChangeObserved = { endings += 1 }

        // The player's own clock goes where the tick says, as it would.
        let inside = hole.start + 2
        await subject.player.seek(to: inside)
        tick(inside)

        #expect(subject.activeEntry == hole)
        #expect(subject.activeFragmentID == sentence.fragmentID)
        #expect(fragments.isEmpty, "the highlight is already on the sentence the hole names")
        #expect(chapters.isEmpty)
        #expect(endings == 0)
        let anchor = try #require(subject.currentAnchor)
        #expect(anchor.audioHref == hole.audioHref)
        #expect(anchor.offset > hole.start && anchor.offset < hole.end,
                "clamped into the sentence, the anchor read \(anchor.offset)")
        #expect(abs(anchor.offset - inside) < 0.001)

        // Out of the hole into the next sentence is a real change.
        tick(next.start + 1)
        #expect(subject.activeEntry == next)
        #expect(fragments == [next.fragmentID])
    }

    @Test("next sentence from a hole is the next sentence, not the one the hole belongs to")
    func nextSentenceFromAHole() async throws {
        let (subject, timeline, directory) = try Self.make()
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries
        let map = CommandMap()
        // The command plays from where it lands. Neither the real clock nor a
        // real end of file may move the entry between the command and the
        // look at where it went.
        subject.player.onTimeUpdate = nil
        subject.player.onFinishedFile = nil

        #expect(await subject.prepare(at: entries[2]))
        await subject.perform(.nextSentence, using: map)
        #expect(subject.activeEntry == entries[3])

        // From the hole that ends chapter one, over the audio chapter.
        #expect(await subject.prepare(at: entries[6]))
        await subject.perform(.nextSentence, using: map)
        #expect(subject.activeEntry == entries[9])

        // And back from a continuation to the sentence before the one it
        // continues.
        #expect(await subject.prepare(at: entries[11]))
        await subject.perform(.previousSentence, using: map)
        #expect(subject.activeEntry == entries[9])
    }

    /// The car and the lock screen play the same chunks through the audiobook
    /// engine. An audio chapter has files of its own and a place in the
    /// contents, so it has tracks and a chapter there too.
    @Test("the synthesised audiobook has the audio chapter's files and its chapter")
    func chunkManifestHasTheAudioChapter() throws {
        let (timeline, package) = try Self.timeline()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-readalong-v3-manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "readalong-v3-manifest", into: directory)

        let result = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files, durations: [:], title: nil)

        #expect(result.manifest.readingOrder.map(\.href) == [
            "OEBPS/Audio/track1.mp3", "OEBPS/Audio/bonus1.mp3", "OEBPS/Audio/bonus2.mp3",
            "OEBPS/Audio/track2a.mp3", "OEBPS/Audio/track2b.mp3", "OEBPS/Audio/track3.mp3",
        ])
        #expect(result.chapters.map(\.title) == [
            "Chapter One", "After Chapter One", "Chapter Two", "Chapter Three",
        ])
        let interlude = try #require(result.chapters.first { $0.title == "After Chapter One" })
        #expect(interlude.trackIndex == 1)
        #expect(interlude.offset == 0)
    }
}

/// The read-along on the other shapes Storyteller 3 writes, which the
/// generated fixture does not reach: word granularity, an audio chapter that
/// opens in the middle of a text chapter's file, and a sentence whose
/// after-holes run through three files. The timelines are stated by hand and
/// played over the v3 fixture's own audio files, which is all the player
/// needs of them.
@MainActor
@Suite("The read-along on the other shapes Storyteller 3 writes")
struct ReadalongV3ShapesTests {
    static let chapterOne = "OEBPS/ch01.xhtml", chapterTwo = "OEBPS/ch02.xhtml"
    static let interlude = "OEBPS/storyteller-audio-1.xhtml"
    static let track1 = "OEBPS/Audio/track1.mp3", track2 = "OEBPS/Audio/track2a.mp3"
    static let bonus1 = "OEBPS/Audio/bonus1.mp3", bonus2 = "OEBPS/Audio/bonus2.mp3"

    /// `cumulativeEnd` accumulated exactly as `SMILParser.timeline(for:)`
    /// accumulates it.
    static func narration(
        _ rows: [(fragment: String, text: String, audio: String,
                  start: TimeInterval, end: TimeInterval, audioOnly: Bool)],
    ) -> SMILTimeline {
        var cumulative: TimeInterval = 0
        return SMILTimeline(entries: rows.map { row in
            cumulative += row.end - row.start
            return SMILEntry(
                fragmentID: row.fragment, textHref: row.text, audioHref: row.audio,
                start: row.start, end: row.end, cumulativeEnd: cumulative,
                isAudioOnly: row.audioOnly)
        })
    }

    static func make(_ timeline: SMILTimeline) throws -> (ReadalongCoordinator, URL) {
        let (parsed, package) = try ReadalongV3Tests.timeline()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-readalong-v3-shapes-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: parsed, bookID: "readalong-v3-shapes", into: directory,
        )
        return (ReadalongCoordinator(timeline: timeline, audioFiles: files), directory)
    }

    /// The loop, one granularity down. The holes name the sentence and the
    /// words between them do not, so resolved through its key the after-hole
    /// was the before-hole, and the end of the file moved to the sentence's
    /// first word and played the sentence and its music again, for ever.
    @Test("a word-granular file that ends in an after-hole advances to the next file")
    func wordGranularFileEndingInAHole() async throws {
        let timeline = Self.narration([
            ("ch01-s0", Self.chapterOne, Self.track1, 0, 6, true),
            ("ch01-s0-w0", Self.chapterOne, Self.track1, 6, 7, false),
            ("ch01-s0-w1", Self.chapterOne, Self.track1, 7, 8, false),
            ("ch01-s0", Self.chapterOne, Self.track1, 8, 20, true),
            ("ch01-s1-w0", Self.chapterOne, Self.track2, 0, 2, false),
            ("ch01-s1-w1", Self.chapterOne, Self.track2, 2, 5, false),
        ])
        let (subject, directory) = try Self.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        #expect(await subject.prepare(at: entries[2]))
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        var fragments: [String] = []
        var endings = 0
        subject.onFragmentChange = { fragments.append($0) }
        subject.onChapterChangeObserved = { endings += 1 }

        // From the last word into the music after it: the highlight goes back
        // out to the whole sentence, as the hole names it.
        tick(14)
        #expect(subject.activeEntry == entries[3])
        #expect(fragments == ["ch01-s0"])

        subject.player.onFinishedFile?()
        let advanced = await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[4] && subject.movesInFlight == 0
        }
        #expect(advanced, "the end of the file went back into the sentence")
        #expect(subject.player.currentAudioHref == Self.track2)
        #expect(endings == 0, "the same chapter carries on")
    }

    ///      0  ch01-s0                 track1  0–30.65
    ///      1  ch01-s5                 track1  30.65–35.75
    ///      2  storyteller_audio_1-a0  track1  35.75–44   the interlude opens mid-file
    ///      3  storyteller_audio_1-a1  bonus1  0–180
    ///      4  storyteller_audio_1-a2  bonus2  0–150
    ///      5  ch02-s0                 track2a 0–5
    ///
    /// What holes.ts plans when chapter one's file ends in a few seconds of
    /// silence and two untitled tracks follow: one run of boundary holes, over
    /// five minutes long, so one audio chapter, starting where the last
    /// sentence of chapter one stops.
    static func untitledTracks() -> SMILTimeline {
        narration([
            ("ch01-s0", chapterOne, track1, 0, 30.65, false),
            ("ch01-s5", chapterOne, track1, 30.65, 35.75, false),
            ("storyteller_audio_1-s0", interlude, track1, 35.75, 44, true),
            ("storyteller_audio_1-s0", interlude, bonus1, 0, 180, true),
            ("storyteller_audio_1-s0", interlude, bonus2, 0, 150, true),
            ("ch02-s0", chapterTwo, track2, 0, 5, false),
        ])
    }

    /// No file boundary to announce it, so the clock does: chapter one has
    /// ended, the page turns to the audio chapter's heading, once.
    @Test("the clock crossing into an audio chapter mid-file turns the page and ends the chapter, once")
    func midFileInterlude() async throws {
        let timeline = Self.untitledTracks()
        let (subject, directory) = try Self.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        #expect(await subject.prepare(at: entries[1]))
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        var fragments: [String] = []
        var chapters: [String] = []
        var endings = 0
        subject.onFragmentChange = { fragments.append($0) }
        subject.onChapterChange = { chapters.append($0) }
        subject.onChapterChangeObserved = { endings += 1 }

        tick(40)
        tick(41)
        #expect(subject.activeEntry == entries[2])
        #expect(fragments == ["storyteller_audio_1-s0"])
        #expect(chapters == [Self.interlude])
        #expect(endings == 1)

        // Its own next two files are the same chapter; the file after is not.
        subject.player.onFinishedFile?()
        #expect(await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[3] && subject.movesInFlight == 0
        })
        subject.player.onFinishedFile?()
        #expect(await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[4] && subject.movesInFlight == 0
        })
        #expect(endings == 1)
        #expect(chapters == [Self.interlude])

        subject.player.onFinishedFile?()
        #expect(await ReadalongV3Tests.waitUntil {
            subject.activeEntry == entries[5] && subject.movesInFlight == 0
        })
        #expect(endings == 2)
        #expect(chapters == [Self.interlude, Self.chapterTwo])
    }

    /// The car's chapter list for the same book: the audio chapter begins in
    /// chapter one's track, where chapter one's narration stops.
    @Test("a mid-file audio chapter is a chapter at its offset into the shared track")
    func midFileInterludeChapter() throws {
        let (_, package) = try ReadalongV3Tests.timeline()
        let chapters = ChunkManifest.chapters(
            timeline: Self.untitledTracks(), package: package,
            trackOrder: [Self.track1, Self.bonus1, Self.bonus2, Self.track2])
        #expect(chapters == [
            AudiobookChapter(title: "Chapter One", trackIndex: 0, offset: 0),
            AudiobookChapter(title: "After Chapter One", trackIndex: 0, offset: 35.75),
            AudiobookChapter(title: "Chapter Two", trackIndex: 3, offset: 0),
        ])
    }

    /// What holes.ts plans for the same audio when the bonus tracks are
    /// titled: each is a run of its own, none reaches five minutes, and the
    /// last sentence of chapter one keeps an after-hole in all three files.
    /// Every one of them names that sentence, and every file ends in one.
    @Test("a sentence's after-holes in three files play through, and chapter one ends once")
    func afterHolesInThreeFiles() async throws {
        let timeline = Self.narration([
            ("ch01-s5", Self.chapterOne, Self.track1, 30.65, 35.75, false),
            ("ch01-s5", Self.chapterOne, Self.track1, 35.75, 44, true),
            ("ch01-s5", Self.chapterOne, Self.bonus1, 0, 180, true),
            ("ch01-s5", Self.chapterOne, Self.bonus2, 0, 150, true),
            ("ch02-s0", Self.chapterTwo, Self.track2, 0, 5, false),
        ])
        let (subject, directory) = try Self.make(timeline)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = timeline.entries

        #expect(await subject.prepare(at: entries[0]))
        let tick = try #require(subject.player.onTimeUpdate)
        subject.player.onTimeUpdate = nil
        var fragments: [String] = []
        var endings = 0
        subject.onFragmentChange = { fragments.append($0) }
        subject.onChapterChangeObserved = { endings += 1 }

        tick(40)
        #expect(subject.activeEntry == entries[1])
        #expect(fragments.isEmpty)

        for index in 2 ... 4 {
            subject.player.onFinishedFile?()
            let advanced = await ReadalongV3Tests.waitUntil {
                subject.activeEntry == entries[index] && subject.movesInFlight == 0
            }
            #expect(advanced, "the end of the file before entry \(index) did not reach it")
            #expect(subject.player.currentAudioHref == entries[index].audioHref)
        }
        #expect(endings == 1, "chapter one ended once, after its last hole")
    }
}
