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

/// Holds the first request it sees until released, so a drain can be caught
/// mid-flight — which is the only state in which the lock means anything.
///
/// Static, because `URLProtocol` instances are made by the loading system, not
/// by the test. `startLoading` runs on URLSession's own queue, so blocking it
/// on a semaphore holds nothing the test or the actors need.
private final class BlockingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gate = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private static var started = 0
    nonisolated(unsafe) private static var blockFirst = true

    static func reset() {
        lock.withLock {
            gate = DispatchSemaphore(value: 0)
            started = 0
            blockFirst = true
        }
    }

    static var requestsStarted: Int { lock.withLock { started } }
    static func release() { lock.withLock { gate }.signal() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (gate, shouldBlock): (DispatchSemaphore, Bool) = Self.lock.withLock {
            Self.started += 1
            defer { Self.blockFirst = false }
            return (Self.gate, Self.blockFirst)
        }
        if shouldBlock { gate.wait() }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor StubTokens: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}

/// Two drains over one queue, one of them caught mid-request.
///
/// The suite this replaces toggled `beginDraining()`/`endDraining()` by hand
/// and never called `drain()`, so deleting the guard left it green. These go
/// through `MutationDrain` against a request that does not return until told
/// to, which is the only way the lock's two behaviours — declining for an
/// ordinary caller, waiting for the exit path — are observable at all.
///
/// `.serialized`: `BlockingProtocol` keeps its gate in static state.
@Suite("Only one drain runs at a time", .serialized)
struct DrainExclusionTests {
    private func makeDrain() async throws -> (MutationDrain, MutationQueue, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-drainlock-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)
        BlockingProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BlockingProtocol.self]
        let client = APIClient(
            baseURL: URL(string: "https://storyteller.test")!,
            tokens: StubTokens(), session: URLSession(configuration: configuration))
        return (MutationDrain(queue: queue, client: client), queue, directory)
    }

    /// Yields until `condition` holds or a bounded number of turns pass.
    private func settle(until condition: @escaping @Sendable () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The original finding, F-5.9: a second drain must not read the same rows
    /// and send them a second time. It declines, and sends nothing.
    @Test("a second drain declines rather than sending the same rows again")
    func secondDrainDeclines() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await queue.enqueue(.status, bookUUID: "a", payload: Data(#"{"status":"reading"}"#.utf8))

        let first = Task { await drain.drain() }
        await settle { BlockingProtocol.requestsStarted == 1 }
        #expect(BlockingProtocol.requestsStarted == 1, "the first drain has to be mid-request")

        let second = await drain.drain()
        #expect(second == 0, "the second caller must decline, not read the same row")
        #expect(BlockingProtocol.requestsStarted == 1, "the row was sent twice")

        BlockingProtocol.release()
        #expect(await first.value == 1)
    }

    /// My regression: the exit path passed through the same decline, so
    /// `flushOpenReaders()` on ⌘Q sent nothing whenever a background drain
    /// happened to be blocked — and on the way out there is no next enqueue.
    /// The waiting form suspends until the lock is handed over, then drains
    /// whatever arrived while the first drain was running.
    @Test("the exit path waits for an in-flight drain and then sends what it left")
    func exitPathWaitsAndSends() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await queue.enqueue(.status, bookUUID: "a", payload: Data(#"{"status":"reading"}"#.utf8))

        let first = Task { await drain.drain() }
        await settle { BlockingProtocol.requestsStarted == 1 }
        // Written while the first drain is blocked; its `pending()` was read
        // before this row existed, so only a drain that runs *after* it can
        // send this one.
        try await queue.enqueue(.status, bookUUID: "b", payload: Data(#"{"status":"reading"}"#.utf8))

        let completed = Completion()
        let waiting = Task {
            let sent = await drain.drain(waitingForInFlight: true)
            completed.mark()
            return sent
        }
        await settle { completed.done }
        #expect(!completed.done, "the exit path declined instead of waiting")
        #expect(BlockingProtocol.requestsStarted == 1)

        BlockingProtocol.release()
        #expect(await first.value == 1)
        #expect(await waiting.value == 1, "the row queued during the first drain was never sent")
        #expect(BlockingProtocol.requestsStarted == 2)
        #expect(try await queue.count == 0)
    }
}

private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var done: Bool { lock.withLock { flag } }
    func mark() { lock.withLock { flag = true } }
}
