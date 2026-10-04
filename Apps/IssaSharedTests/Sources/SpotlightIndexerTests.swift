import CoreSpotlight
import Foundation
import IssaCore
import Testing

@testable import IssaReader_iOS

/// When the library is put into system search again, and what an account's
/// departure does to a pass still running.
@Suite("Spotlight's index of the library", .serialized)
@MainActor
struct SpotlightIndexerTests {
    /// CoreSpotlight as a slow daemon answers it: the first deletion can be
    /// held until the test lets it go, and everything is recorded.
    @MainActor
    final class HeldBackend: SpotlightBackend {
        private(set) var deletes = 0
        private(set) var indexed: [[String]] = []
        var holdsFirstDelete = false
        private var held: CheckedContinuation<Void, Never>?

        func deleteDomain(_: String) async throws {
            deletes += 1
            if holdsFirstDelete, deletes == 1 {
                await withCheckedContinuation { held = $0 }
            }
        }

        func index(_ items: [CSSearchableItem]) async throws {
            indexed.append(items.map(\.uniqueIdentifier))
        }

        var isHolding: Bool { held != nil }

        func release() {
            held?.resume()
            held = nil
        }
    }

    private static func books(_ count: Int = 2) -> [Book] {
        (0 ..< count).map { SharedFixtures.book("Book \($0)", uuid: "book-\($0)") }
    }

    /// Waits a bounded time for a condition the test cannot await directly.
    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0 ..< 200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - R-22

    /// 1.3.0 stored the same `count-newest` string, so an upgrader whose
    /// catalogue had not changed was never re-indexed and Spotlight kept the
    /// HTML blurbs 1.4.0 strips.
    @Test("an index written by 1.3.0 is replaced on upgrade")
    func upgradeReindexes() async {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let books = Self.books()
        // Exactly what 1.3.0 left behind for this catalogue.
        defaults.set(SpotlightIndex.version(of: books), forKey: SpotlightIndexer.versionKey)
        let backend = HeldBackend()
        let indexer = SpotlightIndexer(backend: backend, defaults: defaults)

        await indexer.index(books)

        #expect(backend.indexed.count == 1, "the 1.3.0 index, with its HTML descriptions, was kept")
    }

    /// Every item expires a month after it was indexed, and an unchanged
    /// catalogue was never indexed again — so the whole library dropped out
    /// of Spotlight a month after the last change.
    @Test("an unchanged library is indexed again before its items expire")
    func renewsBeforeExpiry() async {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let books = Self.books()
        let backend = HeldBackend()
        let indexer = SpotlightIndexer(backend: backend, defaults: defaults)
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        await indexer.index(books, now: start)
        #expect(backend.indexed.count == 1)

        await indexer.index(books, now: start.addingTimeInterval(24 * 3600))
        #expect(backend.indexed.count == 1, "a library indexed yesterday was indexed again")

        await indexer.index(books, now: start.addingTimeInterval(20 * 24 * 3600))
        #expect(backend.indexed.count == 2, "twenty days on, nothing renewed the month's expiry")
    }

    @Test("a changed library is indexed at once")
    func changedLibraryReindexes() async {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let backend = HeldBackend()
        let indexer = SpotlightIndexer(backend: backend, defaults: defaults)
        await indexer.index(Self.books(2))
        await indexer.index(Self.books(3))
        #expect(backend.indexed.map(\.count) == [2, 3])
    }

    // MARK: - R-23

    /// A pass still waiting on its deletion when the account leaves went on
    /// to add the departed account's books after `clear()` — titles, bylines
    /// and blurbs answering Home Screen search on a signed-out device.
    @Test("a pass overtaken by the account's departure adds nothing and records nothing")
    func clearSupersedesARunningPass() async {
        let (defaults, suite) = SharedFixtures.scratchDefaults()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let backend = HeldBackend()
        backend.holdsFirstDelete = true
        let indexer = SpotlightIndexer(backend: backend, defaults: defaults)

        let pass = Task { await indexer.index(Self.books()) }
        let held = await Self.eventually { backend.isHolding }
        try? #require(held, "the pass never reached its deletion")

        await indexer.clear()
        backend.release()
        await pass.value

        #expect(backend.indexed.isEmpty, "the departed account's books were put back into Spotlight")
        #expect(defaults.string(forKey: SpotlightIndexer.versionKey) == nil,
                "a version recorded for a library no longer indexed keeps it out for good")
    }
}
