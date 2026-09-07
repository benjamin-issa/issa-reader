import Foundation
import Testing

@testable import IssaPlayback

/// Where a book's extracted narration is allowed to live.
///
/// `removeExtractedAudio` deletes the directory `defaultDirectory(for:)` names,
/// whole. The book id was interpolated straight into `"Audio/\(bookID)"`, so an
/// id of `..` named the storage root and dropping one book's narration deleted
/// every download, the catalogue and the logs with it.
///
/// It needed no hostile server. The orphan sweep decodes book ids out of
/// filenames it finds in the Books directory, so a file called `..-ebook.epub`
/// — which an unzipped archive, a sync client or a restored backup can leave
/// there — was the whole exploit.
///
/// The naming is asserted rather than the damage, and the removal is pointed at
/// a temporary root. On a Mac the storage root is `~/Library/Application
/// Support`: a test that proved the traversal by letting it run would delete the
/// developer's own the first time this regressed, which is not a way to find out.
@Suite("Naming a book's extracted narration")
struct ExtractedAudioPathTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtractedAudioPathTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a book id that is a path traversal names a child of Audio, not its parent",
          arguments: ["..", "../..", "../Books", "/", "a/b", ""])
    func traversalIdentifiersStayInside(_ hostile: String) throws {
        let root = URL(fileURLWithPath: "/tmp/app/Audio", isDirectory: true)
        let named = AudioExtraction.defaultDirectory(for: hostile, in: root)
        #expect(named.standardizedFileURL.deletingLastPathComponent().path
            == root.standardizedFileURL.path,
            "\"\(hostile)\" named something outside Audio")
        #expect(!named.path.contains(".."))
    }

    /// The removal, against a real filesystem, with a sibling of the audio
    /// folder standing in for Books. Before the guard this deleted `parent`.
    @Test("removing a traversal id leaves everything beside the audio folder alone")
    func removalCannotEscape() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appending(path: "Audio", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bystander = parent.appending(path: "Books", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bystander, withIntermediateDirectories: true)
        let book = bystander.appending(path: "a-book.epub")
        try Data(repeating: 0, count: 8).write(to: book)

        AudioExtraction.removeExtractedAudio(for: "..", in: root)

        #expect(FileManager.default.fileExists(atPath: book.path),
                "the removal reached the storage root")
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: parent.path))
    }

    /// The ordinary case still works, and still names what it always named — a
    /// guard that renamed every existing directory would orphan every narration
    /// already on a device.
    @Test("a real uuid names the directory it always did, and is removed")
    func realIdentifiersAreUnchangedAndRemovable() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let uuid = "11111111-1111-4111-8111-111111111111"
        let directory = AudioExtraction.defaultDirectory(for: uuid, in: root)
        #expect(directory.lastPathComponent == uuid)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8).write(to: directory.appending(path: "track.mp3"))

        AudioExtraction.removeExtractedAudio(for: uuid, in: root)

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }
}
