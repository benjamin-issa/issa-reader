import AVFoundation
import Foundation
import IssaCore
import Testing

@testable import IssaPlayback

/// A downloaded audiobook is kept under a name that ends in `.epub`, which
/// AVFoundation will not open as audio. These are what lets it.
@MainActor
@Suite("Audio kept under a name that is not an audio name")
struct AudioFileKindTests {
    private func copy(of source: URL, named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-audio-kind-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    @Test("the first bytes name the type")
    func headers() {
        #expect(AudioFileKind.mimeType(forHeader: Data("ID3\u{3}".utf8)) == "audio/mpeg")
        #expect(AudioFileKind.mimeType(forHeader: Data([0xFF, 0xFB, 0x90, 0x00])) == "audio/mpeg")
        #expect(AudioFileKind.mimeType(forHeader: Data([0xFF, 0xF1, 0x50, 0x80])) == "audio/aac")
        #expect(AudioFileKind.mimeType(forHeader: Data([0, 0, 0, 0x20] + Array("ftypM4B ".utf8))) == "audio/mp4")
        #expect(AudioFileKind.mimeType(forHeader: Data("RIFF\0\0\0\0WAVE".utf8)) == "audio/wav")
        #expect(AudioFileKind.mimeType(forHeader: Data("PK\u{3}\u{4}".utf8)) == nil)
    }

    @Test("a file with an audio name needs no override, and one named .epub does")
    func override() throws {
        let wav = try copy(of: SilentAudio.url, named: "a.wav")
        let epub = try copy(of: SilentAudio.url, named: "id-audiobook.epub")

        #expect(AudioFileKind.overrideMIMEType(forFileAt: wav) == nil)
        #expect(AudioFileKind.overrideMIMEType(forFileAt: epub) == "audio/wav")
    }

    @Test("a file named .epub loads and plays through the coordinator")
    func localDownloadPlays() async throws {
        let epub = try copy(of: SilentAudio.url, named: "id-audiobook.epub")
        let manifest = AudiobookManifest(
            metadata: .init(title: ["und": "One File"]),
            readingOrder: [.init(href: "book.wav", type: "audio/wav", duration: 600)])
        let subject = AudiobookCoordinator(manifest: manifest, source: .local(epub))

        #expect(await subject.start(atProgress: 0) == .landed)
        #expect(subject.player.isPlaying)
    }

    @Test("its length can be measured")
    func measured() async throws {
        let epub = try copy(of: SilentAudio.url, named: "id-audiobook.epub")

        let lengths = await ChunkDurations.measure(["id-audiobook.epub": epub], cached: [:])

        #expect((lengths["id-audiobook.epub"] ?? 0) > 1_000)
    }
}
