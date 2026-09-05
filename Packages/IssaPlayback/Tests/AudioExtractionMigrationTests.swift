import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// A narration extracted under the old filename is moved, not extracted again.
///
/// Files were named by `lastPathComponent` until this branch. The rename that
/// fixed the collision between `Audio/ch01/track.mp3` and `Audio/ch02/track.mp3`
/// shipped with no migration, so every already-extracted book — hundreds of
/// megabytes each — was extracted a second time in full while the old files sat
/// beside the new ones for good.
@Suite("Migrating extracted narration to the new filenames")
struct AudioExtractionMigrationTests {
    static func fixture() throws -> (EPUBPackage, SMILTimeline) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/readalong", withExtension: "epub"))
        let package = try EPUBPackage.open(url: url)
        return (package, SMILParser.timeline(for: package))
    }

    static func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-extract-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("an old-name file whose name only one track claims is moved into place")
    func uniqueLegacyFileIsMoved() throws {
        let (package, timeline) = try Self.fixture()
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hrefs = Set(timeline.entries.map(\.audioHref))
        let byLegacyName = Dictionary(grouping: hrefs) { ($0 as NSString).lastPathComponent }
        let href = try #require(
            byLegacyName.values.first { $0.count == 1 }?.first,
            "the fixture needs at least one track with an unambiguous filename")
        let legacyName = (href as NSString).lastPathComponent
        let newName = AudioExtraction.filename(for: href)
        try #require(legacyName != newName, "a root-level track has nothing to migrate")

        // Bytes the archive does not hold, so a re-extraction is distinguishable
        // from a move.
        let marker = Data("previously extracted".utf8)
        try marker.write(to: directory.appending(path: legacyName))

        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "book", into: directory)

        let destination = try #require(files[href])
        #expect(destination.lastPathComponent == newName)
        #expect(try Data(contentsOf: destination) == marker,
                "the file was extracted again instead of moved")
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: legacyName).path),
                "the old file was left behind")
    }

    @Test("a fresh directory extracts every track once")
    func freshExtraction() throws {
        let (package, timeline) = try Self.fixture()
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }

        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "book", into: directory)
        #expect(files.count == Set(timeline.entries.map(\.audioHref)).count)
        for url in files.values {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
