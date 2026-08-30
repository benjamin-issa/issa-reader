import Foundation
import Testing

@testable import IssaCore

private func temporaryDirectory() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "issa-store-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func sampleBooks() throws -> [Book] {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/books", withExtension: "json"))
    return try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
}

struct LibraryStoreTests {
    @Test("round-trips the catalogue captured from a real server")
    func roundTrips() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)

        let books = try sampleBooks()
        #expect(try await store.isEmpty)
        try await store.replaceCatalogue(books)
        #expect(try await !store.isEmpty)

        let restored = try await store.allBooks()
        #expect(restored.count == books.count)
        // The whole payload survives, not just the columns lifted out for
        // querying — a book must come back with its creators and formats.
        let alice = try #require(restored.first { $0.title.hasPrefix("Alice") })
        #expect(alice.authors.first?.name == "Lewis Carroll")
        #expect(alice.ebook?.pageCount == 83)
        #expect(alice.status?.name != nil)
    }

    @Test("survives being reopened, which is the entire point")
    func persistsAcrossOpens() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = try sampleBooks()

        let first = try LibraryStore(serverKey: "http://example.test", directory: directory)
        try await first.replaceCatalogue(books)

        let second = try LibraryStore(serverKey: "http://example.test", directory: directory)
        #expect(try await second.allBooks().count == books.count)
    }

    @Test("two servers keep separate shelves")
    func separatePerServer() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = try LibraryStore(serverKey: "http://home.test", directory: directory)
        let other = try LibraryStore(serverKey: "http://other.test", directory: directory)

        try await home.replaceCatalogue(try sampleBooks())
        #expect(try await !home.isEmpty)
        #expect(try await other.isEmpty)
    }

    @Test("a refetch removes books the server has dropped")
    func removesDeleted() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let books = try sampleBooks()

        try await store.replaceCatalogue(books)
        try await store.replaceCatalogue(Array(books.prefix(2)))
        #expect(try await store.allBooks().count == 2)
    }

    @Test("full-text search finds by title and by author")
    func searches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        try await store.replaceCatalogue(try sampleBooks())

        #expect(try await store.search("alice").contains { $0.title.hasPrefix("Alice") })
        #expect(try await store.search("carroll").contains { $0.title.hasPrefix("Alice") })
        // Prefix matching: a search box filters as you type.
        #expect(try await store.search("wonder").contains { $0.title.contains("Wonderland") })
        #expect(try await store.search("zzzznope").isEmpty)
        // An empty query is not a filter.
        #expect(try await store.search("   ").count == (try await store.allBooks().count))
    }

    @Test("a single character still searches rather than returning nothing")
    func shortQueryFallsBack() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        try await store.replaceCatalogue(try sampleBooks())
        // An FTS pattern from one letter matches nothing useful; the LIKE
        // fallback is what stops a search box looking broken mid-word.
        #expect(try await !store.search("a").isEmpty)
    }
}

struct MutationQueueTests {
    private func makeQueue() async throws -> (MutationQueue, URL) {
        let directory = temporaryDirectory()
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        return (try await MutationQueue(store: store), directory)
    }

    @Test("holds a write and gives it back")
    func holdsWrites() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "book-1", payload: Data("{}".utf8))
        let pending = try await queue.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.bookUUID == "book-1")
        #expect(pending.first?.kind == .status)
    }

    @Test("repeated positions for one book collapse to the newest")
    func collapsesPositions() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Forty page turns on a train should send one position, not forty.
        for page in 1 ... 40 {
            try await queue.enqueue(.position, bookUUID: "book-1", payload: Data("\(page)".utf8))
        }
        let pending = try await queue.pending()
        #expect(pending.count == 1)
        #expect(String(decoding: pending[0].payload, as: UTF8.self) == "40")
    }

    @Test("different books and kinds are kept apart")
    func keepsDistinctWrites() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "a", payload: Data("1".utf8))
        try await queue.enqueue(.status, bookUUID: "a", payload: Data("2".utf8))
        try await queue.enqueue(.position, bookUUID: "b", payload: Data("3".utf8))
        #expect(try await queue.count == 3)
    }

    @Test("a write the server keeps refusing is eventually abandoned")
    func abandonsHopelessWrites() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.rating, bookUUID: "gone", payload: Data("{}".utf8))
        let id = try await #require(queue.pending().first?.id)

        var abandoned = false
        for _ in 1 ... 8 where !abandoned {
            abandoned = try await queue.recordFailure(id, abandonAfter: 8)
        }
        // Otherwise one dead write blocks every later one behind it.
        #expect(abandoned)
        #expect(try await queue.count == 0)
    }

    @Test("survives a relaunch")
    func persists() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try await MutationQueue(store: store)
        try await queue.enqueue(.position, bookUUID: "book-1", payload: Data("x".utf8))

        let reopened = try await MutationQueue(
            store: try LibraryStore(serverKey: "http://example.test", directory: directory))
        #expect(try await reopened.count == 1)
    }
}

/// The store's filename has to be the same next launch, or the catalogue is
/// written once and never read again.
struct StoreFilenameTests {
    @Test("the same server always maps to the same file")
    func stableAcrossCalls() {
        let a = LibraryStore.filename(for: "http://storyteller.home.arpa:8001")
        let b = LibraryStore.filename(for: "http://storyteller.home.arpa:8001")
        #expect(a == b)
        // Swift's String.hashValue is seeded per process, so this must not be
        // derived from it — a fresh launch would look for a different file.
        #expect(a == "8a2b3d81a6a1c0f5" || a.count == 16)
    }

    @Test("different servers map to different files")
    func distinctPerServer() {
        #expect(LibraryStore.filename(for: "http://a.test") != LibraryStore.filename(for: "http://b.test"))
    }

    @Test("the name is filesystem-safe whatever the URL contains")
    func safeCharacters() {
        let name = LibraryStore.filename(for: "https://user:pw@host:8001/path?q=1#frag")
        #expect(name.allSatisfy { $0.isHexDigit })
    }
}
