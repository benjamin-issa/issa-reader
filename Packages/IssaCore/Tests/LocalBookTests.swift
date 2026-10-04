import Foundation
import Testing

@testable import IssaCore

/// A book the reader added from their own files: how one is made, how it is
/// kept, and how a server is kept from passing one of its own off as one.
@Suite("Books from the reader's files")
struct LocalBookTests {
    static func directory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-local-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    static func copy(notices: [LocalNotice] = []) -> LocalCopy {
        LocalCopy(
            fileName: "peter-and-wendy.epub",
            fingerprint: String(repeating: "ab", count: 32),
            byteCount: 1_048_576,
            importedAt: Date(timeIntervalSince1970: 1_790_000_000),
            hasCover: true,
            packageIdentifier: "urn:uuid:invented",
            epubVersion: "3.0",
            notices: notices)
    }

    static let metadata = LocalBookMetadata(
        title: "The Keeper of the Lamp",
        subtitle: "A Fixture",
        description: "Invented.",
        language: "en",
        date: "2008-06-27",
        authors: [LocalContributor(name: "Ada Fixture", fileAs: "Fixture, Ada", role: "aut")],
        narrators: [LocalContributor(name: "Noel Reader", role: "nrt")],
        creators: [LocalContributor(name: "Iris Illustrator", role: "ill")],
        series: LocalSeries(name: "Lamps and Ledgers", position: 2),
        identifier: "urn:uuid:invented")

    static func uuid() -> String { UUID().uuidString.lowercased() }

    // MARK: - The factory

    @Test("a narrated book is a read-along the app can narrate")
    func alignedBook() {
        let uuid = Self.uuid()
        let book = Book.local(uuid: uuid, metadata: Self.metadata, narrationDuration: 25_440, copy: Self.copy())
        #expect(book.uuid == uuid)
        #expect(book.isLocal)
        #expect(book.hasReadalong)
        #expect(book.readaloud?.isAligned == true)
        #expect(book.servableFormats == [.readaloud])
        #expect(book.narrationDuration == 25_440)
        #expect(book.isReadable)
        #expect(book.ebook == nil)
        #expect(book.title == "The Keeper of the Lamp")
        #expect(book.displaySubtitle == "A Fixture")
        #expect(book.byline == "Ada Fixture")
        #expect(book.narrators.map(\.name) == ["Noel Reader"])
        #expect(book.creators.map(\.role) == ["ill"])
        #expect(book.primarySeries?.name == "Lamps and Ledgers")
        #expect(book.primarySeries?.position == 2)
        #expect(book.createdAt?.value == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(book.publicationDate != nil)
        // Nothing a server would know about.
        #expect(book.status == nil)
        #expect(book.position == nil)
        #expect(book.tags.isEmpty)
    }

    @Test("a book without playable narration is an ebook only")
    func plainBook() {
        for duration in [nil, 0.0] {
            let book = Book.local(
                uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: duration, copy: Self.copy())
            #expect(!book.hasReadalong)
            #expect(book.servableFormats == [.ebook])
            #expect(book.narrationDuration == nil)
            #expect(book.isReadable)
            #expect(book.ebook?.filepath == "book.epub")
        }
    }

    /// Books date themselves by the year or the day far more often than by
    /// the second, which is all a server's dates ever are.
    @Test("a year, a month or a day is a publication date")
    func publicationDates() {
        let utc = { (y: Int, m: Int, d: Int) in
            DateComponents(
                calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: 0),
                year: y, month: m, day: d).date
        }
        #expect(LocalBookMetadata.parseDate("1911") == utc(1911, 1, 1))
        #expect(LocalBookMetadata.parseDate("1911-05") == utc(1911, 5, 1))
        #expect(LocalBookMetadata.parseDate(" 2008-06-27 ") == utc(2008, 6, 27))
        #expect(LocalBookMetadata.parseDate("2026-08-01T07:31:52Z") != nil)
        for nonsense in ["", "c. 1900", "1911-13-01", "19-05", "MCMXI"] {
            #expect(LocalBookMetadata.parseDate(nonsense) == nil, "\(nonsense)")
        }
    }

    @Test("every book gets the uuid it is given, and a fresh one is fresh")
    func freshUUIDs() {
        let a = Book.local(uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: nil, copy: Self.copy())
        let b = Book.local(uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: nil, copy: Self.copy())
        #expect(a.uuid != b.uuid)
        #expect(a.uuid.isBareUUID)
        // Creator ids are the book's own, so two books never share one.
        #expect(Set(a.authors.map(\.uuid)).isDisjoint(with: b.authors.map(\.uuid)))
    }

    @Test("notices a later build adds survive this build's round trip")
    func unknownNotices() throws {
        var copy = Self.copy(notices: [.fixedLayout])
        copy.noticeValues.append("aNoticeFromTheFuture")
        let data = try JSONEncoder().encode(copy)
        var decoded = try JSONDecoder().decode(LocalCopy.self, from: data)
        #expect(decoded.notices == [.fixedLayout])
        decoded.notices = []
        #expect(decoded.noticeValues == ["aNoticeFromTheFuture"])
    }

    // MARK: - The device store

    @Test("a local book survives a round trip through the device store")
    func storeRoundTrip() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: directory)
        let book = Book.local(
            uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: 120,
            copy: Self.copy(notices: [.narrationUnplayable]))
        try await store.upsert(book)

        let reopened = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: directory)
        let restored = try #require(try await reopened.book(book.uuid))
        #expect(restored == book)
        #expect(restored.localCopy?.notices == [.narrationUnplayable])
        #expect(restored.isLocal)
    }

    @Test("the device store is its own file, apart from any server's")
    func deviceStoreIsSeparate() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let device = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: directory)
        let server = try LibraryStore(serverKey: "https://library.example", directory: directory)
        let (deviceFile, serverFile) = (await device.url, await server.url)
        #expect(deviceFile != serverFile)

        let book = Book.local(uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: nil, copy: Self.copy())
        try await device.upsert(book)
        #expect(try await server.allBooks().isEmpty)
        // A server's catalogue replacing itself does not reach the device's.
        try await server.replaceCatalogue([])
        #expect(try await device.allBooks().count == 1)
    }

    @Test("removing a book removes its row and its audio anchor, and nothing else")
    func deletions() async throws {
        let directory = Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: LibraryStore.deviceBooksKey, directory: directory)
        let gone = Book.local(uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: 60, copy: Self.copy())
        let kept = Book.local(uuid: Self.uuid(), metadata: Self.metadata, narrationDuration: 60, copy: Self.copy())
        for book in [gone, kept] {
            try await store.upsert(book)
            try await store.setAudioAnchor(
                AudioAnchor(audioHref: "OEBPS/Audio/1.mp3", offset: 3, writtenAt: 1), forBook: book.uuid)
        }

        try await store.deleteBook(gone.uuid)
        try await store.deleteAudioAnchor(forBook: gone.uuid)

        #expect(try await store.book(gone.uuid) == nil)
        #expect(try await store.audioAnchor(forBook: gone.uuid) == nil)
        #expect(try await store.book(kept.uuid) != nil)
        #expect(try await store.audioAnchor(forBook: kept.uuid) != nil)
    }

    // MARK: - Files

    @Test("a book's files are all inside its own folder")
    func files() {
        let root = Self.directory()
        let uuid = Self.uuid()
        let files = LocalBookFiles(bookUUID: uuid, root: root)
        #expect(files.folder == root.appending(path: uuid, directoryHint: .isDirectory))
        for url in [files.epub, files.cover, files.narration, files.fonts] {
            #expect(url.path.hasPrefix(files.folder.path + "/"))
        }
        #expect(files.epub.lastPathComponent == "book.epub")
        #expect(files.cover.lastPathComponent == "cover.jpg")
        #expect(LocalBookFiles.incoming(in: root).path.hasPrefix(root.path + "/"))
    }

    /// The folder is deleted whole when its book goes, so an id that is not a
    /// uuid must not be able to name anything above it.
    @Test("an id that is not a uuid cannot climb out of the Local folder")
    func unsafeID() {
        let root = Self.directory()
        let files = LocalBookFiles(bookUUID: "..", root: root)
        #expect(files.folder.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(files.folder.lastPathComponent.hasPrefix("unsafe-"))
    }

    // MARK: - A server cannot make a book local

    @Test("server catalogues decode with no local copy")
    func serverBooksAreNotLocal() throws {
        for name in ["Fixtures/books", "Fixtures/v3/books"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
            let books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
            #expect(!books.isEmpty)
            #expect(books.allSatisfy { !$0.isLocal })
        }
    }

    /// The field decodes — the device store depends on it — so the strip is
    /// at the catalogue's boundary, and both doors in through it are checked.
    @Test("a server that sends a local copy has it stripped")
    func serverSentLocalCopyIsStripped() throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/books", withExtension: "json"))
        var json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        let copy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.copy()))
        json[0]["issaLocal"] = copy
        let books = try JSONDecoder().decode([Book].self, from: JSONSerialization.data(withJSONObject: json))
        #expect(books[0].isLocal, "the field has to decode for the strip to mean anything")

        #expect(LibraryService.refusingUnsafeIdentifiers(books).allSatisfy { !$0.isLocal })
        #expect(try !LibraryService.refusingUnsafeIdentifier(books[0]).isLocal)
    }
}
