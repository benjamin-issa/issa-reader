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
