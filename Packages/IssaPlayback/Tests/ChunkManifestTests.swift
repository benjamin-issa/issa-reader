import Foundation
import IssaCore
import IssaEPUB
import Testing

@testable import IssaPlayback

/// Synthesising an audiobook manifest from a read-along's own media overlay.
///
/// The bug: one book, two track lists that share no file name. The read-along
/// plays the EPUB's narration chunks; the server's `listen/manifest.json` lists
/// the original upload, one file named after the book. `AudioAnchor` bridges the
/// two engines by file name and offset, and across those lists nothing ever
/// matches — so a book part-read on the phone started the car at zero, and the
/// fifteen-second writer saved that zero over a part-read novel.
///
/// The fix is not a better match. It is playing the chunks the anchor already
/// names, so a match is not needed at all.
@Suite("A manifest over a book's own narration chunks")
struct ChunkManifestTests {
    static func fixture() throws -> (
        timeline: SMILTimeline, package: EPUBPackage, files: [String: URL], directory: URL
    ) {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-chunk-manifest-\(UUID().uuidString)")
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "chunk-manifest", into: directory)
        return (timeline, package, files, directory)
    }

    /// A narration stated in four lines, rather than an EPUB assembled to hold
    /// one. `cumulativeEnd` is the caller's job — see `SMILEntry.init` — so it
    /// is accumulated here exactly as `SMILParser` accumulates it.
    static func synthetic(
        _ rows: [(href: String, text: String, start: TimeInterval, end: TimeInterval)],
    ) -> SMILTimeline {
        var cumulative: TimeInterval = 0
        var entries: [SMILEntry] = []
        for (index, row) in rows.enumerated() {
            cumulative += max(0, row.end - row.start)
            entries.append(SMILEntry(
                fragmentID: "s\(index)",
                textHref: row.text,
                audioHref: row.href,
                start: row.start,
                end: row.end,
                cumulativeEnd: cumulative,
            ))
        }
        return SMILTimeline(entries: entries)
    }

    // MARK: - The track list

    @Test("tracks follow the overlay's order, one per distinct file")
    func tracksFollowOverlayOrderOnePerDistinctFile() {
        let timeline = Self.synthetic([
            ("b.mp3", "ch01.xhtml", 0, 5),
            ("b.mp3", "ch01.xhtml", 5, 9),
            ("a.mp3", "ch02.xhtml", 0, 4),
            ("c.mp3", "ch03.xhtml", 0, 6),
        ])
        // Reading order, not alphabetical and not the order a Set would hand
        // back: the book clock is the sum of the tracks in front of a track, so
        // the order *is* the clock.
        #expect(ChunkManifest.fileOrder(timeline.entries) == ["b.mp3", "a.mp3", "c.mp3"])
    }

    /// Two tracks with one href would give `AudioAnchor` two answers for one
    /// file. It resolves by first match, so the second would be a stretch of
    /// book clock nothing could ever seek to.
    @Test("a file the book returns to gets one track, at its first position")
    func aRecurringFileGetsOneTrackAtItsFirstPosition() {
        let timeline = Self.synthetic([
            ("a.mp3", "ch01.xhtml", 0, 5),
            ("b.mp3", "ch02.xhtml", 0, 5),
            ("a.mp3", "ch03.xhtml", 5, 9),
        ])
        #expect(ChunkManifest.fileOrder(timeline.entries) == ["a.mp3", "b.mp3"])
    }

    /// SMIL states no file durations at all — only clip times — so the longest
    /// clip end in a file is the best the overlay can offer, and it understates
    /// by however long the file runs on after the last word. A measured length
    /// is the truth and wins.
    @Test("a measured duration wins, and the estimate fills the gaps")
    func measuredDurationWinsAndTheEstimateFillsGaps() throws {
        let (timeline, package, files, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(ChunkManifest.estimatedDuration(of: "OEBPS/Audio/track1.mp3", in: timeline) == 23)
        #expect(ChunkManifest.estimatedDuration(of: "OEBPS/Audio/track2.mp3", in: timeline) == 9.75)

        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: ["OEBPS/Audio/track1.mp3": 42], title: "Fixture")

        #expect(built.manifest.playableTracks[0].duration == 42)
        #expect(built.manifest.playableTracks[1].duration == 9.75)
        #expect(built.manifest.totalDuration == 51.75)
        #expect(built.manifest.metadata.duration == 51.75)
    }

    /// A track with no bytes behind it still takes its share of the book clock,
    /// and every position written afterwards is measured against audio that
    /// cannot play.
    @Test("a chunk with no extracted file is dropped, with its files")
    func aChunkWithNoFileIsDropped() throws {
        let (timeline, package, files, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var partial = files
        partial["OEBPS/Audio/track1.mp3"] = nil

        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: partial,
            durations: [:], title: "Fixture")

        #expect(built.manifest.playableTracks.map(\.href) == ["OEBPS/Audio/track2.mp3"])
        #expect(built.files.keys.sorted() == ["OEBPS/Audio/track2.mp3"])
        // And the chapter that would have played out of the missing chunk goes
        // with it, rather than pointing at a track that is no longer there.
        #expect(built.chapters.map(\.title) == ["Chapter Two"])
        #expect(built.chapters[0].trackIndex == 0)
    }

    @Test("fixture tracks carry archive paths and the OPF's own media types")
    func fixtureTracksCarryArchivePathsAndOPFTypes() throws {
        let (timeline, package, files, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")

        #expect(built.manifest.playableTracks.map(\.href)
            == ["OEBPS/Audio/track1.mp3", "OEBPS/Audio/track2.mp3"])
        #expect(built.manifest.playableTracks.allSatisfy { $0.type == "audio/mpeg" })
        #expect(built.files.count == 2)
    }

    /// The whole point, stated as a round trip: an anchor the read-along wrote
    /// resolves on the synthesised manifest, and the very same anchor resolves
    /// to nothing on the server's — which is the bug, reproduced beside the fix.
    @Test("a read-along's anchor round-trips on the synthesised manifest")
    func readalongAnchorRoundTripsOnTheSynthesisedManifest() throws {
        let (timeline, package, files, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")

        // Exactly what `ReadalongCoordinator` writes: the archive path out of the
        // media overlay, and seconds into that file.
        let anchor = AudioAnchor(audioHref: "OEBPS/Audio/track2.mp3", offset: 5, writtenAt: 0)
        let resolved = try #require(built.manifest.bookTime(for: anchor))
        #expect(resolved == 23 + 5, "the first chunk's length, plus the offset into the second")

        // The same anchor against the server's track list for the same book: one
        // track, named after the upload. Nothing matches, and `nil` is the
        // honest answer — it is also what started the car at zero.
        let original = AudiobookManifest(
            metadata: .init(title: ["und": "Fixture"]),
            readingOrder: [.init(href: "The Patient Record of the Days.mp3", duration: 99_000)],
        )
        #expect(original.bookTime(for: anchor) == nil)
    }

    // MARK: - Chapters

    @Test("chapters group by text document and take their navigation titles")
    func chaptersGroupByTextDocumentAndTakeNavigationTitles() throws {
        let (timeline, package, files, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let built = ChunkManifest.make(
            timeline: timeline, package: package, audioFiles: files,
            durations: [:], title: "Fixture")

        #expect(built.chapters.map(\.title) == ["Chapter One", "Chapter Two"])
        #expect(built.chapters.map(\.trackIndex) == [0, 1])
        #expect(built.chapters.map(\.offset) == [0, 0])
        #expect(built.chapters.map(\.documentHref) == ["OEBPS/ch01.xhtml", "OEBPS/ch02.xhtml"])
    }

    /// Chunks are cut by silence and chapters by the book, so a chapter starts
    /// where it starts. A track list cannot say this at all — which is why
    /// `AudiobookChapter` carries an offset.
    @Test("a chapter can begin part-way through a chunk")
    func aChapterCanBeginMidChunk() throws {
        let (_, package, _, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeline = Self.synthetic([
            ("a.mp3", "OEBPS/ch01.xhtml", 0, 10),
            ("a.mp3", "OEBPS/unlisted.xhtml", 10, 20),
        ])

        let chapters = ChunkManifest.chapters(
            timeline: timeline, package: package, trackOrder: ["a.mp3"])

        #expect(chapters.map(\.trackIndex) == [0, 0], "both live in the same chunk")
        #expect(chapters.map(\.offset) == [0, 10])
        // A document the contents does not list gets a numbered name, not its
        // archive path: a path is not a name anybody wrote.
        #expect(chapters.map(\.title) == ["Chapter One", "Section 2"])
    }

    /// A spine may reference one document twice — a shared notes page, a chapter
    /// split across two itemrefs, both legal. They are two places in the book,
    /// and collapsing them would put a chapter marker tens of minutes from where
    /// the listener is.
    @Test("a revisited document is a second chapter")
    func aRevisitedDocumentIsASecondChapter() throws {
        let (_, package, _, directory) = try Self.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let timeline = Self.synthetic([
            ("a.mp3", "OEBPS/ch01.xhtml", 0, 10),
            ("b.mp3", "OEBPS/ch02.xhtml", 0, 10),
            ("c.mp3", "OEBPS/ch01.xhtml", 0, 10),
        ])

        let chapters = ChunkManifest.chapters(
            timeline: timeline, package: package, trackOrder: ["a.mp3", "b.mp3", "c.mp3"])

        #expect(chapters.map(\.title) == ["Chapter One", "Chapter Two", "Chapter One"])
        #expect(chapters.map(\.trackIndex) == [0, 1, 2])
    }
}
