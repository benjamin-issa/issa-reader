import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// Measured chunk lengths, and where they are kept.
///
/// The book clock a position is written against is the sum of these, so a stale
/// one is a position that resolves to the wrong place in the book. Keeping them
/// beside the extracted audio is what makes staleness impossible: the files and
/// the numbers describing them are deleted by one call.
@Suite("Measuring the narration chunks")
struct ChunkDurationsTests {
    /// A temporary `Audio` root. Never the real one — on a Mac the storage root
    /// is `~/Library/Application Support`, and `removeExtractedAudio` deletes a
    /// directory whole. `AudioExtraction.defaultDirectory` documents the same
    /// reason for taking a root at all.
    static func root() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-durations-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("durations round-trip, and go when the audio they describe goes")
    func durationsRoundTripBesideTheExtractedAudio() throws {
        let root = Self.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let measured: [String: TimeInterval] = [
            "OEBPS/Audio/track1.mp3": 23.4,
            "OEBPS/Audio/track2.mp3": 9.87,
        ]

        try ChunkDurations.save(measured, bookID: "book", in: root)
        #expect(ChunkDurations.load(bookID: "book", in: root) == measured)

        // Inside the directory the extraction writes to, not merely near it.
        let cache = ChunkDurations.cacheURL(bookID: "book", in: root)
        #expect(cache.deletingLastPathComponent().standardizedFileURL
            == AudioExtraction.defaultDirectory(for: "book", in: root).standardizedFileURL)

        AudioExtraction.removeExtractedAudio(for: "book", in: root)
        #expect(FileManager.default.fileExists(atPath: cache.path) == false)
        #expect(ChunkDurations.load(bookID: "book", in: root).isEmpty,
                "lengths must not outlive the files they describe")
    }

    @Test("measuring skips what is already cached, and measures the rest")
    func measureSkipsWhatIsCachedAndMeasuresTheFixture() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let directory = Self.root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "measure", into: directory)

        // A deliberately wrong cached value for one of them: if it were
        // remeasured the number would change, and reopening every chunk on
        // every play is the cost this type exists to avoid.
        let merged = await ChunkDurations.measure(
            files, cached: ["OEBPS/Audio/track1.mp3": 1])

        #expect(merged["OEBPS/Audio/track1.mp3"] == 1, "a cached length is not measured again")
        let second = try #require(merged["OEBPS/Audio/track2.mp3"])
        #expect(second.isFinite && second > 0, "the unmeasured one was measured: \(second)")
        #expect(merged.count == 2)
    }

    /// The measurement is the audio's own length, not a division sum.
    ///
    /// Asked for a duration without being told to be precise, AVFoundation may
    /// answer for an MP3 by dividing the file's size by its declared bitrate.
    /// The fixture's chunks are a single MPEG frame apiece — 1152 samples at
    /// 44.1kHz, 26 milliseconds — inside a 2052-byte file, and that quotient
    /// comes back as 4608 samples: four times the audio that is there.
    ///
    /// Four times is this fixture being small, and a real chunk's error is
    /// fractions of a second. The direction is what matters. Every chunk is
    /// wrong the same way, the errors sum rather than cancel, and the sum is the
    /// book clock a listening position is written against — so over a hundred
    /// and seventy-six chunks the phone and the server come to disagree about
    /// where in the book a reader is by minutes.
    @Test("a chunk is measured by its frames, not by its bitrate")
    func aChunkIsMeasuredByItsFramesRatherThanItsBitrate() async throws {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let directory = Self.root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "precise", into: directory)

        let measured = await ChunkDurations.measure(files, cached: [:])
        #expect(measured.isEmpty == false)

        // One frame, exactly. Sample-accurate, so this is an equality with only
        // enough slack for the division that turns samples into seconds.
        let oneFrame = 1152.0 / 44100.0
        for (href, length) in measured {
            #expect(abs(length - oneFrame) < 0.001,
                    "\(href) measured \(length)s, and one frame is \(oneFrame)s")
        }
    }
}
