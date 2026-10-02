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

    /// A root-level track and a nested one with the same name: under the old
    /// naming both were `intro.mp3`, so that name counts as claimed twice — an
    /// ambiguous leftover, to be deleted and re-extracted. But `intro.mp3` is
    /// also the root-level track's name under the *new* scheme, and when the
    /// root-level track was written first the rescue for the nested one deleted
    /// it: the reader was handed a file that was no longer there.
    @Test("a root-level track is not deleted as another track's legacy name")
    func aSiblingsLiveFileIsNotRescuedAway() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hrefs = ["intro.mp3", "Audio/intro.mp3"]

        let files = try AudioExtraction.extract(
            hrefs: hrefs, read: { Data("bytes of \($0)".utf8) }, into: directory, isCancelled: { false })

        for href in hrefs {
            let url = try #require(files[href])
            #expect(FileManager.default.fileExists(atPath: url.path), "\(href)'s file was deleted")
            #expect((try? Data(contentsOf: url)) == Data("bytes of \(href)".utf8))
        }
    }

    /// The case the rescue exists for, on the same layout: an older build
    /// extracted both under one name, so whichever won is ambiguous, and both
    /// have to come out of the archive again.
    @Test("an ambiguous leftover is replaced by each track's own bytes")
    func anAmbiguousLeftoverIsReplaced() throws {
        let directory = Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("bytes of Audio/intro.mp3".utf8).write(to: directory.appending(path: "intro.mp3"))

        let files = try AudioExtraction.extract(
            hrefs: ["intro.mp3", "Audio/intro.mp3"], read: { Data("bytes of \($0)".utf8) },
            into: directory, isCancelled: { false })

        let root = try #require(files["intro.mp3"])
        #expect((try? Data(contentsOf: root)) == Data("bytes of intro.mp3".utf8),
                "the root-level track kept the nested one's bytes from the old collision")
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
