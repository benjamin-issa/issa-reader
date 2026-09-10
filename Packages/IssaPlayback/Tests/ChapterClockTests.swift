import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// A chapter is a place in the book, not a file.
///
/// Storyteller cuts a read-along's narration into chunks by silence — a hundred
/// and seventy-six files for a novel with forty chapters — so once the app plays
/// those chunks instead of the server's single upload, "the chapter" and "the
/// track" come apart. Everything that used to read `trackIndex` and be right by
/// accident is wrong here: the sleep timer would end the book at the next chunk,
/// the scrubber would call two minutes a chapter, and the mini bar would name
/// the wrong one.
@Suite("Chapters over chunks")
@MainActor
struct ChapterClockTests {
    /// Built through the public initialisers, which is how a synthesised
    /// manifest is built in production too — see `AudiobookManifestInitTests`
    /// for why that is the same manifest the server's JSON decodes into.
    static func manifest(trackCount: Int, each: Double) -> AudiobookManifest {
        AudiobookManifest(
            metadata: .init(title: ["und": "A Book In Chunks"]),
            readingOrder: (0 ..< trackCount).map { index in
                .init(href: "chunk\(index).mp3", type: "audio/mpeg", duration: each)
            },
        )
    }

    /// Every track pointed at an unplayable file.
    ///
    /// `.files` is the source under test, so the tests have to use it even where
    /// the audio is beside the point — `.local` would prove nothing about a
    /// per-track lookup. `/dev/null` is what `BookClockTests` already drives a
    /// real `AudioPlayer` with.
    static func nowhere(_ manifest: AudiobookManifest) -> [String: URL] {
        Dictionary(
            uniqueKeysWithValues: manifest.readingOrder.map {
                ($0.href, URL(fileURLWithPath: "/dev/null"))
            },
        )
    }

    static func coordinator(
        _ manifest: AudiobookManifest,
        chapters: [AudiobookChapter] = [],
        files: [String: URL]? = nil,
    ) -> AudiobookCoordinator {
        AudiobookCoordinator(
            manifest: manifest,
            source: .files(files ?? nowhere(manifest)),
            chapters: chapters,
        )
    }

    /// The coordinator's own clock hook, unhooked from the player.
    ///
    /// These tests state exactly which samples arrive. Against a real (if
    /// unplayable) `AVPlayer` the periodic observer fires on its own with a time
    /// of zero — `BookClockTests` documents the same hazard — which would
    /// overwrite the sample under test between the call and the assertion, and
    /// make a chapter announcement look like it had been withdrawn.
    static func detachClock(_ subject: AudiobookCoordinator) -> (TimeInterval) -> Void {
        let tick = subject.player.onTimeUpdate
        subject.player.onTimeUpdate = nil
        return tick ?? { _ in }
    }

    /// Waits for work that hops through a `Task` — `onFinishedFile` does.
    static func settle(until condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The fixture read-along, synthesised into a manifest over its own chunks.
    static func fixture() throws -> (result: ChunkManifest.Result, directory: URL) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-chapter-clock-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "chapter-clock", into: directory)
        let result = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")
        return (result, directory)
    }

    // MARK: - The source

    /// `.local` hands one URL to every track. A book cut into chunks needs one
    /// per track, or chunk one plays under all of them while the clock counts on.
    @Test("a files source loads the right file for each track")
    func filesSourceLoadsTheRightFilePerTrack() async throws {
        let (built, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let subject = Self.coordinator(built.manifest, files: built.files)
        _ = Self.detachClock(subject)

        let first = try #require(built.manifest.playableTracks.first?.duration)
        await subject.seek(toBookTime: first + 1)

        #expect(subject.trackIndex == 1)
        #expect(subject.player.currentAudioHref == "OEBPS/Audio/track2.mp3")
        // Real bytes behind it, not just the right name: a duration only
        // resolves for an asset AVFoundation could actually open.
        #expect(subject.player.duration > 0)
    }

    /// A half-deleted extraction, or a download removed while the book sat
    /// paused. The old order — index and clock first, then find something to
    /// play — would leave the coordinator claiming a track it never reached,
    /// with the fifteen-second writer persisting progress through silence.
    @Test("a missing chunk file refuses the load and stops cleanly")
    func aMissingChunkFileRefusesTheLoadAndStopsCleanly() async {
        let subject = AudiobookCoordinator(
            manifest: Self.manifest(trackCount: 3, each: 100), source: .files([:]))
        _ = Self.detachClock(subject)

        await subject.start(atProgress: 0)

        #expect(subject.player.currentAudioHref == nil, "nothing may have been loaded")
        #expect(subject.player.isPlaying == false, "a book with no audio must not claim to play")
        #expect(subject.bookTime == 0)
        // And it has no place to offer anybody. `trackIndex` is zero from birth
        // and `bookTime` with it, so this used to answer "chunk one, offset
        // zero" for an engine that had never opened a file — an anchor the
        // hand-off places perfectly well on the overlay's first sentence, and
        // then turns a part-read novel back to page one from.
        #expect(subject.currentAnchor == nil, "an engine that played nothing has nowhere to name")
    }

    // MARK: - Boundaries

    /// The sleep timer's "end of chapter" hangs off `onChapterChangeObserved`
    /// and nothing else. A chunked book crosses a *file* boundary every couple
    /// of minutes; telling the timer that was a chapter ended the book at the
    /// next chunk, which is nowhere a listener would have chosen to stop.
    @Test("the sleep timer hook fires at a chapter boundary, not a chunk boundary")
    func theSleepTimerHookFiresAtAChapterBoundaryNotAChunkBoundary() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 2),
            ],
        )
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        await subject.seek(toBookTime: 99)
        subject.player.play()
        _ = Self.detachClock(subject)
        // A load publishes when it *finishes*; `trackIndex` moves before it
        // awaits, so waiting on that would read the chapter mid-load.
        var loads = 0
        subject.onChapterChange = { _ in loads += 1 }

        // Chunk one runs out. Same chapter on the other side of it.
        subject.player.onFinishedFile?()
        await Self.settle { loads == 1 }
        #expect(subject.trackIndex == 1)
        #expect(observed == 0, "a chunk running out is not a chapter ending")
        #expect(subject.chapterIndex == 0)

        // Chunk two runs out, and chapter B begins with chunk three.
        subject.player.onFinishedFile?()
        await Self.settle { loads == 2 }
        #expect(subject.trackIndex == 2)
        #expect(observed == 1, "this one *is* a chapter ending")
        #expect(subject.chapterIndex == 1)
    }

    /// The other half: a chapter that starts part-way through a chunk ends
    /// under the listener with no file boundary anywhere near it, so the clock
    /// is the only thing that can notice.
    @Test("a mid-chunk chapter boundary is observed from the clock")
    func aMidChunkChapterBoundaryIsObservedFromTheClock() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 0, offset: 50),
            ],
        )
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        await subject.seek(toBookTime: 40)
        let tick = Self.detachClock(subject)
        #expect(subject.chapterIndex == 0)

        tick(52)
        #expect(subject.chapterIndex == 1)
        #expect(subject.chapterTitle == "B")
        #expect(observed == 1)

        // A scrub back over the same boundary moves the chapter and tells the
        // sleep timer nothing: a chapter the listener left is not one that ended.
        await subject.seek(toBookTime: 10)
        #expect(subject.chapterIndex == 0)
        #expect(observed == 1, "a scrub is not a chapter ending")
    }

    /// Every duration a media overlay can offer is an estimate — the last clip
    /// ends a beat before the file does — so the clock runs past a track's
    /// stated end while that same file is still playing. Announcing the next
    /// file's chapter from that arithmetic names a chapter before a word of it
    /// has been spoken.
    @Test("a tick past a short stated duration does not announce the next file's chapter")
    func aTickPastAShortStatedDurationDoesNotAnnounceTheNextFilesChapter() async {
        let subject = Self.coordinator(Self.manifest(trackCount: 3, each: 1_000))
        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        await subject.seek(toBookTime: 0)
        let tick = Self.detachClock(subject)

        tick(1_005)
        #expect(subject.chapterIndex == 0, "still inside chunk one, whatever the clock says")
        #expect(observed == 0)

        // The file genuinely ending is the one thing that moves between files.
        var loads = 0
        subject.onChapterChange = { _ in loads += 1 }
        subject.player.onFinishedFile?()
        await Self.settle { loads == 1 }
        #expect(subject.trackIndex == 1)
        #expect(subject.chapterIndex == 1)
        #expect(observed == 1)
    }

    /// A deliberate scrub is not a chapter ending.
    ///
    /// The path: `skip(by:)` → `seek(toBookTime:)`'s same-track branch, which
    /// loads nothing and so is not covered by `loadsInFlight` → `await
    /// player.seek` → the player's periodic observer fires with the *post*-seek
    /// time → the clock crosses the boundary the scrub had already crossed, and
    /// the tick claims the crossing. `NowPlayingController` hands that to
    /// `SleepTimer.chapterDidEnd()`, and the book pauses mid-skip.
    @Test("a scrub across a chapter boundary never reaches the sleep timer")
    func aScrubAcrossAChapterBoundaryIsNotAChapterEnding() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 0, offset: 50),
            ],
        )
        // Loads chunk one, so the scrub below is the same-track branch. Stated
        // absolutely rather than through `skip(by:)`, which reads a book clock
        // the real player's first tick may already have written zero over.
        await subject.seek(toBookTime: 40)
        let tick = Self.detachClock(subject)

        var observed = 0
        var announced: [Int] = []
        subject.onChapterChangeObserved = { observed += 1 }
        subject.onChapterChange = { announced.append($0) }

        // The tick the periodic observer delivers mid-seek, made deterministic:
        // this task is enqueued on the main actor before the seek begins, and
        // the actor is not free again until the seek suspends inside
        // `AVPlayer.seek` — which is exactly the window the race lives in.
        let racing = Task { @MainActor in tick(60) }
        await subject.seek(toBookTime: 60)
        await racing.value

        #expect(subject.chapterIndex == 1, "the scrub crossed the boundary")
        #expect(announced.contains(1), "and said so, for Now Playing and the UI")
        #expect(observed == 0, "but a chapter the listener scrubbed past did not end")
    }

    /// The other sample, and why setting the clock first is not enough alone.
    ///
    /// One carrying a *pre*-seek time lands mid-seek and drags the announced
    /// chapter back to where the scrub started. That move fires nothing itself
    /// — going backwards is never an ending — but it leaves the coordinator a
    /// chapter behind the audio, and the next honest sample then reads `0 → 1`
    /// as an advance and hands the sleep timer an "end of chapter" one tick
    /// late, in the middle of the same deliberate skip.
    @Test("a stale sample delivered mid-seek does not end a chapter one tick late")
    func aStaleSampleMidSeekDoesNotEndAChapterLate() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 0, offset: 50),
            ],
        )
        await subject.seek(toBookTime: 40)
        let tick = Self.detachClock(subject)

        var observed = 0
        subject.onChapterChangeObserved = { observed += 1 }

        // The player still reporting where it was when the seek began. Enqueued
        // before the seek starts, so it runs at the seek's own suspension point
        // — and it reports back what the counter said, because a sample that
        // landed outside the window would prove nothing.
        let racing = Task { @MainActor () -> Int in
            let inFlight = subject.seeksInFlight
            tick(40)
            return inFlight
        }
        await subject.seek(toBookTime: 60)
        #expect(await racing.value == 1, "the stale sample has to land inside the seek")

        // And now the clock catches up with the audio, honestly.
        tick(60)

        #expect(subject.chapterIndex == 1, "the scrub crossed the boundary and stayed across it")
        #expect(subject.chapterTitle == "B")
        #expect(observed == 0, "nothing ended under the listener, one tick later or ever")
    }

    /// `ChunkManifest.fileOrder` gives each chunk one track, at its first
    /// appearance — it must, or one file would answer to two stretches of book
    /// clock — so an overlay that comes back to a chunk hands a *later* chapter
    /// an *earlier* track. The timeline `(a.mp3, ch01, 0-5), (b.mp3, ch02,
    /// 0-5), (a.mp3, ch03, 5-9)` is two tracks, nine seconds and five, whose
    /// chapters start at 0, 9 and 5.
    ///
    /// Every reader of those starts broke at once: the binary search answered
    /// with chapter one for a time inside chapter three, `chapterSpan` computed
    /// `5 - 9` and gave the scrubber the whole book, and `nextChapter()` seeked
    /// backwards and marked it `.chosen`.
    @Test("a chapter that starts before the one in front of it is dropped")
    func aChapterThatGoesBackwardsIsDropped() async throws {
        let manifest = AudiobookManifest(
            metadata: .init(title: ["und": "A Book In Chunks"]),
            readingOrder: [
                .init(href: "a.mp3", type: "audio/mpeg", duration: 9),
                .init(href: "b.mp3", type: "audio/mpeg", duration: 5),
            ],
        )
        let subject = Self.coordinator(
            manifest,
            chapters: [
                AudiobookChapter(title: "One", trackIndex: 0),
                AudiobookChapter(title: "Two", trackIndex: 1),
                AudiobookChapter(title: "Three", trackIndex: 0, offset: 5),
            ],
        )
        _ = Self.detachClock(subject)

        // The two sound ones kept, not one chapter per track for the whole
        // book: forty good boundaries are not worth losing to one bad one.
        #expect(subject.chapters.map(\.title) == ["One", "Two"])

        await subject.seek(toBookTime: 6)
        #expect(subject.chapterIndex == 0)
        #expect(subject.chapterTitle == "One")
        let first = try #require(subject.chapterSpan)
        #expect(first.start == 0)
        #expect(first.duration == 9)

        await subject.seek(toBookTime: 11)
        #expect(subject.chapterIndex == 1, "not the chapter the bad start sorted in front of")
        #expect(subject.chapterTitle == "Two")
        let second = try #require(subject.chapterSpan)
        #expect(second.start == 9)
        #expect(second.duration == 5, "and it runs to the end of the book, not backwards")
    }

    // MARK: - What the surfaces read

    @Test("the chapter span and title cover the chapter, not the chunk")
    func chapterSpanAndTitleCoverTheChapterNotTheChunk() async throws {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 1, offset: 30),
            ],
        )
        _ = Self.detachClock(subject)

        var span = try #require(subject.chapterSpan)
        #expect(span.start == 0)
        #expect(span.duration == 130, "chapter A runs to where B starts, not to chunk one's end")
        #expect(subject.chapterTitle == "A")

        await subject.seek(toBookTime: 150)
        span = try #require(subject.chapterSpan)
        #expect(subject.chapterIndex == 1)
        #expect(span.start == 130)
        #expect(span.duration == 170, "and B runs to the end of the book")
        #expect(subject.chapterTitle == "B")
    }

    /// Picking a chapter from CarPlay's Up Next, or from the phone's list. The
    /// track's start is the end of the *previous* chapter when a chapter begins
    /// mid-chunk.
    @Test("playing a chapter lands on its start inside its chunk")
    func playChapterLandsOnTheChapterStartInsideItsChunk() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 1, offset: 30),
            ],
        )
        _ = Self.detachClock(subject)

        await subject.play(chapter: 1)

        #expect(subject.trackIndex == 1)
        #expect(abs(subject.bookTime - 130) < 0.001, "landed at \(subject.bookTime)")
        #expect(subject.chapterIndex == 1)
        #expect(subject.consumeSteering(), "the listener named this place")
    }

    /// "Previous" a few seconds in restarts the chapter. Measured on the book
    /// clock against the chapter's start: a chapter beginning mid-chunk is
    /// already thirty seconds into its *file* the moment it starts, so the
    /// player's own clock would restart a chapter nobody had heard yet.
    @Test("previous chapter restarts a mid-chunk chapter before leaving it")
    func previousChapterRestartsAMidChunkChapter() async {
        let subject = Self.coordinator(
            Self.manifest(trackCount: 3, each: 100),
            chapters: [
                AudiobookChapter(title: "A", trackIndex: 0),
                AudiobookChapter(title: "B", trackIndex: 1, offset: 30),
            ],
        )
        let tick = Self.detachClock(subject)

        await subject.play(chapter: 1)
        _ = subject.consumeSteering()
        tick(40) // ten seconds into chapter B, forty into its chunk
        #expect(abs(subject.bookTime - 140) < 0.001)

        await subject.previousChapter()
        #expect(subject.trackIndex == 1, "a restart stays in the same chunk")
        #expect(abs(subject.bookTime - 130) < 0.001, "back to B's start, not chunk one's")
        #expect(subject.chapterIndex == 1)

        // And from the start of a chapter, it moves back one.
        await subject.previousChapter()
        #expect(subject.chapterIndex == 0)
        #expect(subject.trackIndex == 0)
        #expect(subject.bookTime == 0)
    }

    /// Today's behaviour, unchanged, for every book that plays the server's own
    /// manifest: no chapters passed means one chapter per track, named as the
    /// manifest names it.
    @Test("without chapters, every track is a chapter")
    func withoutChaptersEveryTrackIsAChapter() async throws {
        let subject = Self.coordinator(Self.manifest(trackCount: 3, each: 100))
        _ = Self.detachClock(subject)

        #expect(subject.chapters.map(\.title) == ["Track 1", "Track 2", "Track 3"])

        for index in 0 ..< 3 {
            await subject.seek(toBookTime: Double(index) * 100 + 1)
            let span = try #require(subject.chapterSpan)
            #expect(subject.chapterIndex == index)
            #expect(span.start == Double(index) * 100)
            #expect(span.duration == 100, "a chapter is exactly its track here")
        }
    }
}
