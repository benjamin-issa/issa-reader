import Foundation
import Testing

@testable import IssaAsk

/// Sign-out takes every account's question index and keeps the device's.
///
/// A book the reader added from their own files belongs to the device, not to
/// whichever account was signed in when its index was built, so sign-out's
/// purge keeps its index and takes the rest.
@Suite("Purging question indexes around the device's own books")
struct AskIndexKeepTests {
    @Test("a kept book's index survives, everything else goes")
    func keepsOnlyTheKept() async throws {
        let (store, source, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        let kept = store.indexURL(for: AskFixture.bookUUID)
        // Another book's finished index, a half-built one, and their journals:
        // all of it the account's.
        let other = store.indexURL(for: "11111111-1111-4111-8111-111111111111")
        let strays = [
            other, URL(fileURLWithPath: other.path + "-wal"),
            other.deletingPathExtension().appendingPathExtension("building.sqlite"),
        ]
        for stray in strays { try Data("index".utf8).write(to: stray) }
        try #require(FileManager.default.fileExists(atPath: kept.path))

        await store.removeAll(keeping: [AskFixture.bookUUID])

        #expect(FileManager.default.fileExists(atPath: kept.path), "the device's book lost its index")
        let prepared = await store.isPrepared(source: source)
        #expect(prepared, "the kept index must still answer")
        for stray in strays {
            #expect(!FileManager.default.fileExists(atPath: stray.path), "\(stray.lastPathComponent) outlived the account")
        }
    }

    @Test("keeping nothing is removing everything")
    func keepingNothing() async throws {
        let (store, _, directory) = try await AskFixture.preparedStore()
        defer { AskFixture.remove(directory) }
        await store.removeAll(keeping: [])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
