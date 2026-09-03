import Foundation
import Testing
@testable import IssaCore

/// The root everything writable hangs off, and the migration that would eat it.
@Suite("Where the app is allowed to write")
struct StorageRootTests {
    @Test("a named directory is a directory under the root")
    func namedDirectory() {
        let books = StorageRoot.directory("Books")
        #expect(books.lastPathComponent == "Books")
        #expect(books.hasDirectoryPath)
        #expect(books.deletingLastPathComponent().standardizedFileURL
            == StorageRoot.url.standardizedFileURL)
    }

    #if !os(tvOS)
    /// The promise the tvOS fix had to keep: nothing moves anywhere else.
    @Test("off tvOS the root is still Application Support, and is not purgeable")
    func rootIsUnchangedOffTV() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #expect(StorageRoot.url.standardizedFileURL == support.standardizedFileURL)
        #expect(StorageRoot.isPurgeable == false)
        #expect(BookContentService.defaultDirectory().standardizedFileURL
            == support.appending(path: "Books", directoryHint: .isDirectory).standardizedFileURL)
    }
    #endif

    @Test("migrating moves the files and takes the old folder with it")
    func migrationMoves() throws {
        let manager = FileManager.default
        let base = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let from = base.appending(path: "Caches/Books", directoryHint: .isDirectory)
        let to = base.appending(path: "Support/Books", directoryHint: .isDirectory)
        try manager.createDirectory(at: from, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: from.appending(path: "a-ebook.epub"))
        defer { try? manager.removeItem(at: base) }

        BookContentService.migrate(from: from, to: to)

        #expect(manager.fileExists(atPath: to.appending(path: "a-ebook.epub").path))
        #expect(!manager.fileExists(atPath: from.path))
    }

    /// The trap this fix set for itself. Once tvOS writes to Caches, the old
    /// migration's source and destination are the same folder: every file is
    /// skipped as already present and then the folder is deleted — the whole
    /// library, on every launch.
    @Test("migrating a folder onto itself leaves every file alone")
    func migrationOntoItselfIsSafe() throws {
        let manager = FileManager.default
        let books = URL.temporaryDirectory.appending(path: UUID().uuidString)
            .appending(path: "Books", directoryHint: .isDirectory)
        try manager.createDirectory(at: books, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: books.appending(path: "a-readaloud.epub"))
        defer { try? manager.removeItem(at: books.deletingLastPathComponent()) }

        BookContentService.migrate(from: books, to: books)

        #expect(manager.fileExists(atPath: books.appending(path: "a-readaloud.epub").path))
    }

    @Test("a download failure says what went wrong, and does not blame the network")
    func downloadErrorCarriesItsReason() {
        let refusal = "You don't have permission to save the file “Books”."
        let error = StorytellerError.download(refusal)
        #expect(error.errorDescription == refusal)
        #expect(error.recoverySuggestion == nil)
        #expect(AppFacingError.text(for: error) == refusal)
        #expect(IssaLog.describe(error)["download"] == refusal)
    }
}
