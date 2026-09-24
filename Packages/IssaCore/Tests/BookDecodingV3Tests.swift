import Foundation
import Testing

@testable import IssaCore

/// These decode a real `GET /api/v2/books` response captured from a running
/// Storyteller `web-v3.0.0-beta.40` server (Tests/Fixtures/v3/books.json),
/// migrated from the same library as the 2.14.21 capture, with the shapes 3.x
/// adds put there on purpose: "Read" relabelled "Finished", a custom
/// "Abandoned" status, and two books whose status was cleared — one of them
/// with a position.
@Suite("Decoding a Storyteller 3.x catalogue")
struct BookDecodingV3Tests {
    private func books() throws -> [Book] {
        try JSONDecoder().decode([Book].self, from: BookDecodingTests.fixture("v3/books"))
    }

    private func book(_ title: String) throws -> Book {
        try #require(try books().first { $0.title == title }, "no \(title) in the capture")
    }

    /// First, and on the whole array: one book that fails to decode throws the
    /// entire catalogue away, so a refresh on a 3.x server would update
    /// nothing. Per-book assertions below would never notice that.
    @Test("the whole 3.x library decodes, every book of it")
    func decodesWholeLibrary() throws {
        let books = try books()
        #expect(books.count == 25)
        #expect(LibraryService.refusingUnsafeIdentifiers(books).count == 25)
    }

    @Test("a cleared status decodes as no status")
    func nullStatus() throws {
        #expect(try book("Emma").status == nil)
        let timeMachine = try book("The Time Machine")
        #expect(timeMachine.status == nil)
        #expect(timeMachine.progress == 0.3, "the one with a position, for the shelf rule")
    }

    /// 3.x fixes the built-in names and puts the admin's wording in `label`.
    @Test("a relabelled status keeps its name and shows its label")
    func relabelledStatus() throws {
        let status = try #require(try book("Peter and Wendy").status)
        #expect(status.name == Status.readName)
        #expect(status.label == "Finished")
        #expect(status.displayName == "Finished")
    }

    @Test("a custom status carries its own name as its label")
    func customStatus() throws {
        let status = try #require(try book("Moby Dick; Or, The Whale").status)
        #expect(status.name == "Abandoned")
        #expect(status.displayName == "Abandoned")
    }

    @Test("each format carries its own cover reference")
    func coverReferences() throws {
        let peter = try book("Peter and Wendy")
        let ebook = try #require(peter.ebook?.cover)
        let audiobook = try #require(peter.audiobook?.cover)
        let readaloud = try #require(peter.readaloud?.cover)
        #expect(ebook.sha256 == "59965a29b5d464a02877c179a65183efefe8bec52fd55b8df86e4394c675f7e2")
        #expect(audiobook.sha256 == "35480043e658db2732bcfd22d98a8e990b287973cbf568f85306fb0e2e0cef3b")
        #expect(readaloud == ebook, "the read-along was made from this ebook")
        #expect([ebook, audiobook, readaloud].allSatisfy { $0.isUsable })

        // Every ebook in the capture has art; a missing format is nil whole.
        let books = try books()
        #expect(books.allSatisfy { $0.ebook?.cover?.isUsable == true })
        #expect(try book("Emma").audiobook == nil)
    }

    /// The choice 3.x's own cover route makes: `audio` → audiobook, otherwise
    /// ebook, else read-along.
    @Test("portrait is the ebook's cover, else the read-along's; square is the audiobook's")
    func coverShapeMapping() throws {
        let peter = try book("Peter and Wendy")
        #expect(peter.coverReference(for: .portrait) == peter.ebook?.cover)
        #expect(peter.coverReference(for: .square) == peter.audiobook?.cover)

        var noEbookArt = peter
        noEbookArt.ebook?.cover = nil
        noEbookArt.readaloud?.cover = CoverReference(sha256: String(repeating: "e", count: 64))
        #expect(noEbookArt.coverReference(for: .portrait) == noEbookArt.readaloud?.cover)

        var noEbook = peter
        noEbook.ebook = nil
        #expect(noEbook.coverReference(for: .portrait) == peter.readaloud?.cover)

        var badEbookArt = noEbookArt
        badEbookArt.ebook?.cover = CoverReference(sha256: "NOT-A-SHA")
        #expect(badEbookArt.coverReference(for: .portrait) == noEbookArt.readaloud?.cover)

        let emma = try book("Emma")
        #expect(emma.coverReference(for: .square) == nil, "no audiobook, no square art")
        #expect(emma.coverReference(for: .portrait) == emma.ebook?.cover)
    }

    @Test("the 3.x status list decodes with its labels")
    func statusList() throws {
        let statuses = try JSONDecoder().decode(
            [Status].self, from: BookDecodingTests.fixture("v3/statuses"))
        #expect(statuses.map(\.name) == ["To read", "Reading", "Read", "Abandoned"])
        #expect(statuses.map(\.displayName) == ["To read", "Reading", "Finished", "Abandoned"])
        #expect(statuses.first { $0.name == Status.toReadName }?.isDefault == true)
    }

    @Test("a 2.14.21 catalogue still decodes, with no cover references and no labels")
    func v2HasNoV3Fields() throws {
        let books = try JSONDecoder().decode([Book].self, from: BookDecodingTests.fixture("books"))
        #expect(books.count == 5)
        for book in books {
            #expect(book.ebook?.cover == nil)
            #expect(book.audiobook?.cover == nil)
            #expect(book.readaloud?.cover == nil)
            #expect(book.coverReference(for: .portrait) == nil)
            #expect(book.coverReference(for: .square) == nil)
            let status = try #require(book.status)
            #expect(status.label == nil)
            #expect(status.displayName == status.name)
        }
        let statuses = try JSONDecoder().decode(
            [Status].self, from: BookDecodingTests.fixture("statuses"))
        #expect(statuses.allSatisfy { $0.label == nil && $0.displayName == $0.name })
    }

    /// The cache stores a re-encoding of `Book`, not the server's bytes, so a
    /// field that does not survive the encoder is lost on the next launch.
    @Test("cover references and labels survive the local store")
    func survivesTheStore() async throws {
        let books = try books()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-v3-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://storyteller.test", directory: directory)

        try await store.replaceCatalogue(books)
        let restored = try await store.allBooks()
        #expect(restored.count == books.count)
        for book in books {
            let back = try #require(restored.first { $0.uuid == book.uuid })
            #expect(back.ebook?.cover == book.ebook?.cover)
            #expect(back.audiobook?.cover == book.audiobook?.cover)
            #expect(back.readaloud?.cover == book.readaloud?.cover)
            #expect(back.status == nil ? book.status == nil : back.status?.label == book.status?.label)
            #expect(back.status?.displayName == book.status?.displayName)
        }

        let peter = try #require(restored.first { $0.title == "Peter and Wendy" })
        #expect(peter.status?.displayName == "Finished")
        #expect(peter.coverReference(for: .square)?.sha256.hasPrefix("35480043") == true)
    }
}
