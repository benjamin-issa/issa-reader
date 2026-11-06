import Foundation
import Testing

@testable import IssaCore

/// A row of `GET /books` this client cannot read costs that row.
///
/// The rows below are bad in a way no server sends today, on purpose: the
/// value of this type is the next surprise, not the last one.
@Suite("A catalogue loses only the rows it cannot read")
struct CatalogueTests {
    static let uuids = [
        "11111111-1111-4111-8111-111111111111",
        "22222222-2222-4222-8222-222222222222",
        "33333333-3333-4333-8333-333333333333",
    ]

    static func row(_ uuid: String, title: String = "A book") -> [String: Any] {
        [
            "uuid": uuid, "title": title,
            "authors": [], "narrators": [], "creators": [], "collections": [],
            "identifiers": [], "tags": [], "series": [],
        ]
    }

    /// A book with one field the model cannot read.
    static func unreadableRow(_ uuid: String) -> [String: Any] {
        var json = row(uuid)
        json["rating"] = "five"
        return json
    }

    static func decode(_ rows: [Any]) throws -> Catalogue {
        try JSONDecoder().decode(Catalogue.self, from: JSONSerialization.data(withJSONObject: rows))
    }

    /// First, middle and last, by identity. A loop that stopped at the bad
    /// row, or skipped the row after it, passes a test that only looks at the
    /// count or only at one position.
    @Test("a bad row costs that book and no other, wherever it is", arguments: 0 ..< uuids.count)
    func aBadRowCostsThatBook(_ position: Int) throws {
        var rows = Self.uuids.map { Self.row($0) }
        rows[position] = Self.unreadableRow(Self.uuids[position])

        let catalogue = try Self.decode(rows)

        var survivors = Self.uuids
        survivors.remove(at: position)
        #expect(catalogue.books.map(\.uuid) == survivors)
        #expect(catalogue.unreadable == [Self.uuids[position]])
        #expect(!catalogue.hasUnnamedRows)
        #expect(!catalogue.isComplete)
    }

    @Test("several bad rows in a row are all stepped over")
    func consecutiveBadRows() throws {
        let catalogue = try Self.decode(
            [Self.unreadableRow(Self.uuids[0]), Self.unreadableRow(Self.uuids[1]), Self.row(Self.uuids[2])])
        #expect(catalogue.books.map(\.uuid) == [Self.uuids[2]])
        #expect(catalogue.unreadable == [Self.uuids[0], Self.uuids[1]])
    }

    @Test("a row that cannot say which book it was is told apart from one that can")
    func unnamedRows() throws {
        var noUUID = Self.row(Self.uuids[1])
        noUUID["uuid"] = nil

        let unnamedRows: [Any] = [noUUID, 42, "a string"]
        for unnamed in unnamedRows {
            let catalogue = try Self.decode([Self.row(Self.uuids[0]), unnamed, Self.row(Self.uuids[2])])
            #expect(catalogue.books.map(\.uuid) == [Self.uuids[0], Self.uuids[2]])
            #expect(catalogue.unreadable.isEmpty)
            #expect(catalogue.hasUnnamedRows)
        }
    }

    @Test("an empty library is a complete one")
    func anEmptyLibrary() throws {
        let catalogue = try LibraryService.checked(try Self.decode([]))
        #expect(catalogue.books.isEmpty)
        #expect(catalogue.isComplete)
    }

    @Test("a body that is not an array is not a catalogue")
    func notAnArray() {
        let data = Data(#"{"message": "nope"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Catalogue.self, from: data)
        }
    }

    /// Some books the model cannot read is a shelf with gaps. No book it can
    /// read is a client that no longer understands this server, which has to
    /// reach the reader as an error rather than as "No books yet".
    @Test("no readable row at all is an error, not an empty library")
    func nothingReadable() throws {
        let catalogue = try Self.decode([Self.unreadableRow(Self.uuids[0]), Self.unreadableRow(Self.uuids[1])])
        let error = #expect(throws: StorytellerError.self) {
            try LibraryService.checked(catalogue)
        }
        guard case .decoding? = error else {
            Issue.record("expected a decoding error, got \(String(describing: error))")
            return
        }
    }

    /// Any row that can be read is worth having, with the positions and
    /// statuses it carries, however many beside it cannot. Dropping the answer
    /// because most of it failed stalled sync for the books that were fine.
    @Test("one readable row is worth having, however many beside it are not")
    func mostRowsUnreadable() throws {
        let catalogue = try LibraryService.checked(try Self.decode([
            Self.unreadableRow(Self.uuids[0]), Self.row(Self.uuids[1]), Self.unreadableRow(Self.uuids[2]),
        ]))
        #expect(catalogue.books.map(\.uuid) == [Self.uuids[1]])
        #expect(catalogue.unreadable == [Self.uuids[0], Self.uuids[2]])
    }

    /// Weighed after the refusal, or a row refused as a book still counts as
    /// one read, and the reader is told they have no books.
    @Test("a row refused for its uuid does not count as one that was read")
    func refusedRowsAreNotReadable() throws {
        let catalogue = try Self.decode([Self.row("../../Documents/x"), Self.unreadableRow(Self.uuids[0])])
        #expect(throws: StorytellerError.self) { try LibraryService.checked(catalogue) }
    }

    @Test("a uuid that could not name a path is not kept for")
    func unsafeUnreadableRows() throws {
        let hostile = "../../Documents/x"
        let catalogue = try LibraryService.checked(
            try Self.decode([Self.row(Self.uuids[0]), Self.unreadableRow(hostile)]))
        #expect(catalogue.books.map(\.uuid) == [Self.uuids[0]])
        #expect(catalogue.unreadable.isEmpty)
    }

    @Test("every server's library decodes with a read-along being redone, every row of it",
          arguments: CapturedServer.allCases)
    func capturesMidRestart(_ server: CapturedServer) throws {
        let data = try server.booksMidRestart()
        let catalogue = try JSONDecoder().decode(Catalogue.self, from: data)
        #expect(catalogue.isComplete)
        #expect(catalogue.books.contains { $0.title == "The Gap Book" })
    }

    // MARK: - What a device keeps

    private func held() throws -> [Book] {
        try Self.decode(Self.uuids.map { Self.row($0, title: "Here") }).books
    }

    private func shelf(_ rows: [Any]) throws -> [Book] {
        let catalogue = try Self.decode(rows)
        return catalogue.shelf(fresh: catalogue.books, previous: try held())
    }

    /// First, middle and last, by identity and by place. Appended instead, a
    /// book being re-aligned jumped to the end of the grid for the whole job.
    @Test("a book that could not be read stays where the server listed it", arguments: 0 ..< uuids.count)
    func keptInPlace(_ position: Int) throws {
        var rows = Self.uuids.map { Self.row($0, title: "Fresh") }
        rows[position] = Self.unreadableRow(Self.uuids[position])

        let books = try shelf(rows)

        #expect(books.map(\.uuid) == Self.uuids)
        #expect(books[position].title == "Here", "the copy held here, not the row that failed")
    }

    /// Counted from the raw row, the second kept book landed one place late,
    /// past the fresh book that follows it.
    @Test("a row with no copy held here does not push the next one along")
    func keptAfterARowNotHeld() throws {
        let stranger = "44444444-4444-4444-8444-444444444444"
        let catalogue = try Self.decode([
            Self.unreadableRow(stranger), Self.unreadableRow(Self.uuids[0]),
            Self.row(Self.uuids[1]), Self.unreadableRow(Self.uuids[2]),
        ])
        let books = catalogue.shelf(fresh: catalogue.books, previous: try held())
        #expect(books.map(\.uuid) == Self.uuids)
    }

    @Test("what was not listed is not kept")
    func keptOnlyIfListed() throws {
        let books = try shelf([Self.row(Self.uuids[0]), Self.unreadableRow(Self.uuids[1])])
        #expect(books.map(\.uuid) == [Self.uuids[0], Self.uuids[1]])
    }

    @Test("a row that could be any book keeps every book the answer left out")
    func unnamedRowKeepsEverything() throws {
        let books = try shelf([Self.row(Self.uuids[0]), 42])
        #expect(books.map(\.uuid) == Self.uuids)
    }

    /// A shelf with one uuid on it twice is a grid with one identity twice.
    @Test("a book listed both ways is not held twice")
    func listedBothWays() throws {
        let books = try shelf([Self.row(Self.uuids[0]), Self.unreadableRow(Self.uuids[0])])
        #expect(books.map(\.uuid) == [Self.uuids[0]])
    }

    @Test("a complete answer is the shelf as it stands")
    func completeAnswer() throws {
        let catalogue = try Self.decode(Self.uuids.reversed().map { Self.row($0) })
        #expect(catalogue.shelf(fresh: catalogue.books, previous: try held()).map(\.uuid)
            == Self.uuids.reversed())
    }

    // MARK: - The store

    private func storeHolding(_ uuids: [String]) async throws -> (LibraryStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "catalogue-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "http://storyteller.test", directory: directory)
        try await store.replaceCatalogue(try Self.decode(uuids.map { Self.row($0) }).books)
        return (store, directory)
    }

    @Test("a book the server listed and this client could not read stays in the store")
    func storeKeepsWhatItCouldNotRead() async throws {
        let (store, directory) = try await storeHolding(Self.uuids)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalogue = try Self.decode([
            Self.row(Self.uuids[0]), Self.unreadableRow(Self.uuids[1]),
        ])
        try await store.replaceCatalogue(catalogue.books, keeping: catalogue.unreadable)

        #expect(try await store.book(Self.uuids[1]) != nil, "the unreadable book was kept")
        #expect(try await store.book(Self.uuids[2]) == nil, "a book not listed has still gone")
    }

    @Test("an unnamed row deletes nothing, because it could be any book")
    func storePrunesNothingOnAnUnnamedRow() async throws {
        let (store, directory) = try await storeHolding(Self.uuids)
        defer { try? FileManager.default.removeItem(at: directory) }

        let catalogue = try Self.decode([Self.row(Self.uuids[0]), 42])
        try await store.replaceCatalogue(
            catalogue.books, keeping: catalogue.unreadable, prunes: !catalogue.hasUnnamedRows)

        #expect(try await store.allBooks().count == Self.uuids.count)
    }
}
