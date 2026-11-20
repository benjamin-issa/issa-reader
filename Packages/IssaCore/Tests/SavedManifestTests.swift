import Foundation
import Testing

@testable import IssaCore

/// The track list kept beside an audiobook download, so the file can be played
/// with no server to ask for it.
@Suite("The manifest saved with an audiobook download")
struct SavedManifestTests {
    private struct Tokens: TokenProviding {
        func currentToken() async -> String? { nil }
        func invalidate() async {}
    }

    private static let uuid = "0198ab12-cd34-4e56-8f90-123456789abc"

    private func fixture() throws -> (content: BookContentService, book: Book, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "issa-manifest-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = APIClient(
            baseURL: URL(string: "https://library.example")!, tokens: Tokens(),
            session: URLSession(configuration: .ephemeral))
        let json = Data(#"{"uuid":"\#(Self.uuid)","title":"T","authors":[],"narrators":[],"creators":[],"series":[],"collections":[],"identifiers":[],"tags":[]}"#.utf8)
        let book = try JSONDecoder().decode(Book.self, from: json)
        return (BookContentService(client: client, cacheDirectory: directory), book, directory)
    }

    private let manifest = AudiobookManifest(
        metadata: .init(title: ["und": "T"], duration: 90),
        readingOrder: [.init(href: "book.mp3", type: "audio/mpeg", title: "One", duration: 90)])

    @Test("a saved manifest reads back as it was kept")
    func roundTrips() throws {
        let (content, book, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(content.savedManifest(for: book) == nil, "a download made before this was kept has none")

        try content.saveManifest(manifest, for: book)

        #expect(content.savedManifest(for: book) == manifest)
    }

    @Test("the manifest is not taken for a download")
    func isNotADownload() throws {
        let (content, book, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try content.saveManifest(manifest, for: book)

        #expect(try BookContentService.downloadedBookUUIDs(in: directory).isEmpty)
    }

    @Test("removing the audiobook removes its manifest, and no other edition's removal does")
    func goesWithTheAudiobook() throws {
        let (content, book, directory) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try content.saveManifest(manifest, for: book)

        content.removeDownload(book, format: .ebook)
        #expect(content.savedManifest(for: book) != nil)

        content.removeDownload(book, format: .audiobook)
        #expect(content.savedManifest(for: book) == nil)
    }
}
