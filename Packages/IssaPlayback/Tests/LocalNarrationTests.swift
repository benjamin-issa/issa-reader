import Foundation
import IssaEPUB
import Testing

@testable import IssaPlayback

/// Narration in a book from the reader's own files: whether this device can
/// play it, decided before the book is added, and where it is extracted to and
/// removed from.
@Suite("Narration in books from the reader's files")
struct LocalNarrationTests {
    static func url(_ name: String) throws -> URL {
        // IssaPlayback's own fixtures hold the two read-alongs; the generated
        // local-import books live with IssaEPUB's, one level over.
        if let bundled = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "epub") {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "IssaEPUB/Tests/Fixtures/\(name).epub")
        try #require(FileManager.default.fileExists(atPath: source.path), "\(name).epub is missing")
        return source
    }

    @Test("AVFoundation's answer decides, by media type and then by extension")
    func playability() {
        #expect(AudioPlayability.isPlayable(mediaType: "audio/mpeg", href: "a.mp3"))
        #expect(AudioPlayability.isPlayable(mediaType: "audio/mp4", href: "a.m4a"))
        #expect(!AudioPlayability.isPlayable(mediaType: "audio/opus", href: "a.opus"))
        // No media type: the extension stands in for one.
        #expect(AudioPlayability.isPlayable(mediaType: nil, href: "OEBPS/Audio/a.mp3"))
        #expect(!AudioPlayability.isPlayable(mediaType: "", href: "OEBPS/Audio/a"))
    }

    @Test("a read-along with MP3 narration can be narrated")
    func mp3Narrates() throws {
        #expect(AudioPlayability.canNarrate(try EPUBInspection.inspect(Self.url("readalong"))))
    }

    @Test("a read-along with Opus narration cannot, and is added as text")
    func opusDoesNot() throws {
        let inspection = try EPUBInspection.inspect(Self.url("readalong-opus"))
        #expect(inspection.hasCompleteNarration, "the narration is there; only the format is wrong")
        #expect(!AudioPlayability.canNarrate(inspection))
    }

    @Test("a book with no narration has none to play")
    func noNarration() throws {
        #expect(!AudioPlayability.canNarrate(try EPUBInspection.inspect(Self.url("epub2-meta-cover"))))
    }

    /// The book's own folder, under the lock an extraction into it holds:
    /// removing the book while its narration is still being written must not
    /// leave a torn folder, nor be undone by the extraction finishing.
    @Test("narration extracted into a book's own folder is removed from there")
    func removesFromTheBooksFolder() throws {
        let url = try Self.url("readalong")
        let package = try EPUBPackage.open(url: url)
        let timeline = SMILParser.timeline(for: package)
        let folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-local-narration-\(UUID().uuidString)/Audio", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }

        let files = try AudioExtraction.extractAudio(
            from: package, timeline: timeline, bookID: "ignored-for-an-explicit-folder", into: folder)
        #expect(files.values.allSatisfy { $0.path.hasPrefix(folder.path) })
        #expect(files.count == 2)

        AudioExtraction.removeExtractedAudio(at: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}
