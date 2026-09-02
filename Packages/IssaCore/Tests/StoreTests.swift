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

    /// An empty catalogue is still the truth — every book was deleted
    /// server-side, or this account lost access to all of them. Guarding on
    /// the empty list used to keep the whole stale library on the shelf, and
    /// in search, until sign-out.
    @Test("a refetch that returns nothing empties the shelf")
    func removesEverythingWhenServerListsNothing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)

        try await store.replaceCatalogue(try sampleBooks())
        try await store.replaceCatalogue([])
        #expect(try await store.isEmpty)
        // The FTS index must empty with the table, or search resurrects
        // books the shelf no longer shows.
        #expect(try await store.search("alice").isEmpty)
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

    /// The bug this fixes: the index carried `title` and `byline` only, and
    /// `byline` is authors — so a narrator on a book that *has* an author, and
    /// every series and tag, returned nothing at all.
    @Test("search reaches narrator, series, tag and subtitle, not just title and author")
    func searchesEveryPromisedField() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        try await store.replaceCatalogue(try sampleBooks())

        func hitsAlice(_ query: String) async throws -> Bool {
            try await store.search(query).contains { $0.title.hasPrefix("Alice") }
        }

        #expect(try await hitsAlice("hoban"))            // narrator
        #expect(try await hitsAlice("piranesi"))         // series
        #expect(try await hitsAlice("fantasy"))          // tag
        #expect(try await hitsAlice("afternoon"))        // subtitle
        // And the two that already worked must keep working.
        #expect(try await hitsAlice("carroll"))
        #expect(try await hitsAlice("alice"))
    }

    /// The whole basis for not requiring a catalogue refresh: `json` already
    /// holds the entire encoded `Book`, so a row written before the new columns
    /// existed can be repaired locally, offline.
    @Test("the migration backfills rows that were written before the new columns")
    func migrationBackfillsExistingRows() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = try sampleBooks()

        // Write with the current schema, then blank the derived columns to
        // stand in for a row that predates them, and confirm a rebuild from
        // `json` alone restores searchability.
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        try await store.replaceCatalogue(books)
        try await store.eraseSearchFieldsForTesting()
        #expect(try await store.search("hoban").isEmpty)

        try await store.backfillSearchFieldsForTesting()
        #expect(try await store.search("hoban").contains { $0.title.hasPrefix("Alice") })
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
        return (try MutationQueue(store: store), directory)
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

    /// A later position supersedes an earlier one, as before.
    @Test("a later position replaces the one waiting to be sent")
    func newerPositionReplacesOlder() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("100".utf8), supersedes: 100)
        try await queue.enqueue(.position, bookUUID: "b", payload: Data("200".utf8), supersedes: 200)
        let pending = try await queue.pending()
        #expect(pending.count == 1)
        #expect(String(decoding: pending[0].payload, as: UTF8.self) == "200")
    }

    /// The failure this exists for. A position generated out of order used to
    /// delete the queued one unconditionally — and while offline the queue is
    /// the only copy of where the reader is, so the good write was simply gone.
    @Test("an earlier position does not erase a later one waiting to be sent")
    func olderPositionDoesNotEraseNewer() async throws {
        let (queue, directory) = try await makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("200".utf8), supersedes: 200)
        let recorded = try await queue.enqueue(
            .position, bookUUID: "b", payload: Data("100".utf8), supersedes: 100)

        #expect(recorded == false, "the older write should be dropped, not queued")
        let pending = try await queue.pending()
        #expect(pending.count == 1)
        #expect(String(decoding: pending[0].payload, as: UTF8.self) == "200",
                "the newer write must survive")
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
        let queue = try MutationQueue(store: store)
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
        // Pinned to the value SHA-256 actually gives this key (verify with
        // `printf 'http://storyteller.home.arpa:8001' | shasum -a 256 | cut -c1-16`);
        // any per-process derivation cannot reproduce it across launches.
        #expect(a == "960d97ea20ca5a43")
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

/// Signing out has to take the account's books with it.
///
/// The bug: the token was cleared and the rows were not, and `connect()` showed
/// the cached shelf before authenticating — so a signed-out device walked past
/// the sign-in screen into a full library, across a cold launch.
@Suite("Signing out")
struct SignOutCleanupTests {
    @Test("the catalogue goes, and the reader's own annotations stay")
    func clearsBooksButKeepsAnnotations() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-signout-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)

        let url = try #require(Bundle.module.url(forResource: "Fixtures/books", withExtension: "json"))
        let books = try JSONDecoder().decode([Book].self, from: Data(contentsOf: url))
        try await store.replaceCatalogue(books)
        let annotation = Annotation(
            bookUUID: books[0].uuid, kind: .bookmark,
            locator: ReadiumLocator(
                href: "chapter1.xhtml", type: "application/xhtml+xml",
                locations: .init(progression: 0.1, totalProgression: 0.1, charOffset: 10)),
            excerpt: "kept")
        try await store.save(annotation)

        try await store.clearAccountData()

        #expect(try await store.isEmpty)
        #expect(try await store.annotations(for: books[0].uuid).count == 1)
    }

    /// The store is per server and the server serves more than one reader:
    /// a second account on a shared device was handed the first one's
    /// highlights and quoted excerpts.
    @Test("a second account on the same server sees none of the first one's marks")
    func annotationsArePerAccount() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-accounts-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        func mark(_ excerpt: String) -> Annotation {
            Annotation(
                bookUUID: "shared-book", kind: .highlight,
                locator: ReadiumLocator(
                    href: "chapter1.xhtml", type: "application/xhtml+xml",
                    locations: .init(progression: 0.1, totalProgression: 0.1, charOffset: 10)),
                excerpt: excerpt)
        }

        // Made before the upgrade that records accounts.
        try await store.save(mark("legacy"))

        try await store.setAccount("alice")
        try await store.save(mark("alice's"))
        try await store.clearAccountData()

        try await store.setAccount("bob")
        try await store.save(mark("bob's"))
        #expect(try await store.annotations(for: "shared-book").map(\.excerpt) == ["bob's"])
        #expect(try await store.allAnnotations().map(\.excerpt) == ["bob's"])
        try await store.deleteAnnotations(forBook: "shared-book")

        // The first account to sign in after the upgrade owns the legacy
        // rows, and nothing another account did since touched hers.
        try await store.setAccount("alice")
        #expect(Set(try await store.allAnnotations().map(\.excerpt)) == ["legacy", "alice's"])
    }
}
