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
}
