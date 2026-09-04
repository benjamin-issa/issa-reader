import Foundation
import Testing

@testable import IssaCore

/// `enqueue`'s collapse: a newer write for the same book and kind replaces the
/// queued one, and what it inherits from it.
struct MutationQueueCollapseTests {
    private func makeQueue() throws -> (MutationQueue, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-queue-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        return (try MutationQueue(store: store), directory)
    }

    /// A position the server keeps refusing is re-enqueued by every page turn.
    /// Each collapse used to insert a brand-new row with `attempts = 0`, so the
    /// item never reached the abandon limit and blocked the queue forever.
    @Test("a collapsed write inherits the failures of the one it replaces")
    func collapseCarriesAttempts() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("1".utf8), supersedes: 1)
        let first = try #require(await queue.pending().first)
        for _ in 1 ... 3 {
            #expect(try await queue.recordFailure(first.id) == false)
        }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("2".utf8), supersedes: 2)
        let pending = try await queue.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.attempts == 3)
        #expect(pending.first?.payload == Data("2".utf8), "the newer payload still wins")
        #expect(pending.first?.createdAt == first.createdAt, "and it keeps its place in the drain order")
    }

    @Test("the inherited count still reaches the abandon limit")
    func inheritedAttemptsCanAbandon() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("1".utf8), supersedes: 1)
        for round in 1 ... 8 {
            let item = try #require(await queue.pending().first)
            let abandoned = try await queue.recordFailure(item.id)
            #expect(abandoned == (round == 8))
            if !abandoned {
                try await queue.enqueue(
                    .position, bookUUID: "b", payload: Data("\(round)".utf8), supersedes: Double(round + 1))
            }
        }
        #expect(try await queue.pending().isEmpty)
    }

    @Test("an older write does not replace a newer queued one")
    func olderWriteIsDropped() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.position, bookUUID: "b", payload: Data("new".utf8), supersedes: 10)
        let recorded = try await queue.enqueue(
            .position, bookUUID: "b", payload: Data("old".utf8), supersedes: 5)
        #expect(!recorded)
        #expect(try await queue.pending().first?.payload == Data("new".utf8))
    }

    @Test("a fresh write for a book with nothing queued starts at zero")
    func freshWriteStartsClean() async throws {
        let (queue, directory) = try makeQueue()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "b", payload: Data("{}".utf8))
        let item = try #require(await queue.pending().first)
        #expect(item.attempts == 0)
    }
}

@Suite("A pre-migration row still says how new it is")
struct MutationOrderingFallbackTests {
    private func temporary() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-order-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func payload(_ timestamp: Double) throws -> Data {
        try JSONEncoder().encode(MutationDrain.PositionPayload(
            locator: ReadiumLocator(
                href: "c1.xhtml", type: "application/xhtml+xml",
                locations: .init(progression: 0.6, totalProgression: 0.6, charOffset: 1)),
            timestamp: timestamp))
    }

    /// The guard bound `ordering` with `let`, so a NULL column skipped it
    /// entirely — and every row written before `v4-mutation-ordering` has one,
    /// since that migration added the column with no backfill. An out-of-order
    /// write then deleted a good position and replaced it with an older one.
    @Test("an older write cannot replace a queued one whose ordering column is NULL")
    func nullOrderingStillProtects() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)

        // A row as the old build left it: a real payload, no ordering column.
        try await queue.enqueue(.position, bookUUID: "b", payload: payload(2_000))
        try await queue.clearOrderingForTesting(bookUUID: "b")

        // An older write arrives. It must not win.
        let replaced = try await queue.enqueue(
            .position, bookUUID: "b", payload: payload(1_000), supersedes: 1_000)
        #expect(!replaced, "the queued row is newer; it may be the only copy of the reader's place")

        let held = try await queue.pending().first
        let decoded = try JSONDecoder().decode(
            MutationDrain.PositionPayload.self, from: #require(held).payload)
        #expect(decoded.timestamp == 2_000)
    }

    @Test("a newer write still replaces it")
    func newerStillWins() async throws {
        let directory = temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)

        try await queue.enqueue(.position, bookUUID: "b", payload: payload(2_000))
        try await queue.clearOrderingForTesting(bookUUID: "b")
        let replaced = try await queue.enqueue(
            .position, bookUUID: "b", payload: payload(3_000), supersedes: 3_000)
        #expect(replaced)
    }
}

@Suite("Only one drain runs at a time")
struct DrainExclusionTests {
    @Test("a second drain declines rather than sending the same rows again")
    func secondDrainDeclines() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-drainlock-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)

        #expect(await queue.beginDraining(), "the first caller takes the lock")
        #expect(await queue.beginDraining() == false, "the second must not read the same rows")
        await queue.endDraining()
        #expect(await queue.beginDraining(), "and it is released again")
        await queue.endDraining()
    }
}
