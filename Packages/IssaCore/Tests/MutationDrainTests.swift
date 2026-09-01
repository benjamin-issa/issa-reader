import Foundation
import Testing

@testable import IssaCore

/// `drain()` against a real `APIClient`, stubbed at the `URLProtocol` level so
/// the HTTP status codes that actually drive its error handling are exercised,
/// rather than only the classification logic in isolation.
private actor StubTokenProvider: TokenProviding {
    func currentToken() async -> String? { "test-token" }
    func invalidate() async {}
}

/// Hands out one status code per request, in the order given, then 200 for
/// anything beyond that — so a test states exactly what the server does to
/// each successive item without needing to know which item is sent first.
private final class StatusQueueProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var queue: [Int] = []
    nonisolated(unsafe) private static var requestCount = 0

    static func prime(_ statuses: [Int]) {
        lock.withLock {
            queue = statuses
            requestCount = 0
        }
    }

    static var requestsMade: Int {
        lock.withLock { requestCount }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = Self.lock.withLock { () -> Int in
            Self.requestCount += 1
            return Self.queue.isEmpty ? 200 : Self.queue.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Serialized: `StatusQueueProtocol` holds its stub queue in `static` state
/// because `URLProtocol` instances are created by the URL loading system, not
/// by the test, so there is nowhere else to put per-test configuration.
/// Running these concurrently would let one test's responses answer another's
/// requests.
@Suite("Draining the mutation queue against real HTTP responses", .serialized)
struct MutationDrainTests {
    private func makeDrain() async throws -> (MutationDrain, MutationQueue, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "issa-drain-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = try LibraryStore(serverKey: "http://example.test", directory: directory)
        let queue = try MutationQueue(store: store)

        StatusQueueProtocol.prime([])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StatusQueueProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = APIClient(
            baseURL: URL(string: "https://storyteller.test")!,
            tokens: StubTokenProvider(), session: session)
        return (MutationDrain(queue: queue, client: client), queue, directory)
    }

    /// The regression this exists for. A 401 on the first item used to fall
    /// into the "will never succeed, discard it" branch with no `break`, so the
    /// loop carried on to every item behind it — and since the whole session's
    /// token is what's bad, every one of those also 401ed and was also
    /// discarded. One expired token silently emptied the entire backlog.
    @Test("an expired token stops the drain and keeps every item queued")
    func expiredTokenKeepsEverythingQueued() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "a", payload: Data(#"{"status":"reading"}"#.utf8))
        try await queue.enqueue(.status, bookUUID: "b", payload: Data(#"{"status":"reading"}"#.utf8))
        try await queue.enqueue(.status, bookUUID: "c", payload: Data(#"{"status":"reading"}"#.utf8))
        #expect(try await queue.count == 3)

        StatusQueueProtocol.prime([401, 200, 200])
        let sent = await drain.drain()

        #expect(sent == 0, "nothing should count as sent once the session is bad")
        #expect(try await queue.count == 3, "every item, not just the one that 401ed, must survive")
        // The loop must stop at the first 401 rather than trying the rest.
        #expect(StatusQueueProtocol.requestsMade == 1)
    }

    /// The item-specific case, which must keep working exactly as before: a
    /// refusal that is about *this* write does not stop the others.
    @Test("a refusal specific to one item does not block the rest of the queue")
    func itemSpecificRefusalDoesNotBlockOthers() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "gone", payload: Data(#"{"status":"reading"}"#.utf8))
        try await queue.enqueue(.status, bookUUID: "fine", payload: Data(#"{"status":"reading"}"#.utf8))
        #expect(try await queue.count == 2)

        // 404 (not found) on one item, 200 on the other — order-independent:
        // whichever item hits 404 is dropped, whichever hits 200 is sent, and
        // either way the queue should end up empty.
        StatusQueueProtocol.prime([404, 200])
        let sent = await drain.drain()

        #expect(sent == 1)
        #expect(try await queue.count == 0)
        #expect(StatusQueueProtocol.requestsMade == 2, "both items should have been attempted")
    }

    @Test("a genuine transport failure stops the drain but keeps the item for retry")
    func transportFailureStopsAndKeeps() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "a", payload: Data(#"{"status":"reading"}"#.utf8))
        try await queue.enqueue(.status, bookUUID: "b", payload: Data(#"{"status":"reading"}"#.utf8))

        // 500 is retryable, so it falls to the generic `catch`, which records a
        // failure and also breaks — this is the existing behaviour, asserted so
        // a future change to the 401 handling cannot accidentally merge the two.
        StatusQueueProtocol.prime([500, 200])
        let sent = await drain.drain()

        #expect(sent == 0)
        #expect(try await queue.count == 2, "a retryable failure must not discard anything")
        #expect(StatusQueueProtocol.requestsMade == 1)
    }

    /// 409 means the server already holds something newer, so ours is obsolete
    /// rather than failed and dropping it is right. Asserted because it is one
    /// of only two branches that throw a write away, and both used to do it in
    /// complete silence — a server refusing every position looked exactly like
    /// a client that never sent one, with nothing in the log either way.
    @Test("a superseded write is dropped, and the rest of the queue still goes")
    func supersededWriteIsDroppedWithoutBlocking() async throws {
        let (drain, queue, directory) = try await makeDrain()
        defer { try? FileManager.default.removeItem(at: directory) }

        try await queue.enqueue(.status, bookUUID: "stale", payload: Data(#"{"status":"reading"}"#.utf8))
        try await queue.enqueue(.status, bookUUID: "fresh", payload: Data(#"{"status":"reading"}"#.utf8))

        StatusQueueProtocol.prime([409, 200])
        let sent = await drain.drain()

        #expect(sent == 1, "the 409 is not a send")
        #expect(try await queue.count == 0, "an obsolete write must not be kept forever")
        #expect(StatusQueueProtocol.requestsMade == 2, "409 must not stop the drain")
    }
}
