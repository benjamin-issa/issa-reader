import Foundation
import GRDB

/// Writes that have not reached the server yet.
///
/// Every change a reader makes — where they got to, which shelf a book is on,
/// what they rated it — is recorded here *before* the network is attempted, and
/// drained when there is a connection. Without it, a chapter read on a train is
/// simply lost, and a status set in a lift silently rolls back.
///
/// Repeated positions for the same book collapse to the newest: a reader who
/// turns forty pages offline should send one position, not forty.
public actor MutationQueue {
    public enum Kind: String, Codable, Sendable {
        case position
        case status
        case rating
    }

    public struct Pending: Sendable, Hashable {
        public let id: Int64
        public let bookUUID: String
        public let kind: Kind
        public let payload: Data
        public let createdAt: Date
        public let attempts: Int
    }

    private let dbQueue: DatabaseQueue

    public init(store: LibraryStore) async throws {
        dbQueue = try DatabaseQueue(path: await store.url.path)
    }

    /// Records an intent. Positions replace any earlier pending position for the
    /// same book; status and rating likewise, since only the latest matters.
    public func enqueue(_ kind: Kind, bookUUID: String, payload: Data) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM mutation WHERE bookUUID = ? AND kind = ?",
                arguments: [bookUUID, kind.rawValue],
            )
            try db.execute(
                sql: """
                    INSERT INTO mutation (bookUUID, kind, payload, createdAt, attempts)
                    VALUES (?, ?, ?, ?, 0)
                    """,
                arguments: [bookUUID, kind.rawValue, payload, Date().timeIntervalSince1970],
            )
        }
    }

    public func pending() throws -> [Pending] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM mutation ORDER BY createdAt ASC").compactMap { row in
                guard let kind = Kind(rawValue: row["kind"] as String) else { return nil }
                return Pending(
                    id: row["id"],
                    bookUUID: row["bookUUID"],
                    kind: kind,
                    payload: row["payload"],
                    createdAt: Date(timeIntervalSince1970: row["createdAt"]),
                    attempts: row["attempts"],
                )
            }
        }
    }

    public func remove(_ id: Int64) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM mutation WHERE id = ?", arguments: [id])
        }
    }

    /// Records a failed attempt, and gives up after enough of them.
    ///
    /// A write the server keeps refusing — a book deleted server-side, a
    /// permission revoked — must not be retried forever, or it blocks every
    /// later write behind it.
    public func recordFailure(_ id: Int64, abandonAfter limit: Int = 8) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE mutation SET attempts = attempts + 1 WHERE id = ?", arguments: [id])
            let attempts = try Int.fetchOne(
                db, sql: "SELECT attempts FROM mutation WHERE id = ?", arguments: [id]) ?? 0
            if attempts >= limit {
                try db.execute(sql: "DELETE FROM mutation WHERE id = ?", arguments: [id])
                return true
            }
            return false
        }
    }

    public var count: Int {
        get throws { try dbQueue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM mutation") ?? 0 } }
    }

    public func removeAll() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM mutation") }
    }
}

/// Sends what the queue holds, and keeps what it cannot send.
public struct MutationDrain: Sendable {
    private let queue: MutationQueue
    private let client: APIClient

    public init(queue: MutationQueue, client: APIClient) {
        self.queue = queue
        self.client = client
    }

    public struct PositionPayload: Codable, Sendable {
        public let locator: ReadiumLocator
        public let timestamp: Double
        public init(locator: ReadiumLocator, timestamp: Double) {
            self.locator = locator
            self.timestamp = timestamp
        }
    }

    public struct StatusPayload: Codable, Sendable {
        public let status: String
        public init(status: String) { self.status = status }
    }

    public struct RatingPayload: Codable, Sendable {
        public let rating: Double?
        public init(rating: Double?) { self.rating = rating }
    }

    /// Attempts every pending write, oldest first.
    ///
    /// - Returns: how many were accepted.
    @discardableResult
    public func drain() async -> Int {
        guard let pending = try? await queue.pending(), !pending.isEmpty else { return 0 }
        var sent = 0

        for item in pending {
            do {
                try await send(item)
                try? await queue.remove(item.id)
                sent += 1
            } catch StorytellerError.positionConflict {
                // The server has something newer. Ours is obsolete, not failed.
                try? await queue.remove(item.id)
            } catch let error as StorytellerError where !error.isRetryable {
                // A refusal that will not change on the next attempt.
                try? await queue.remove(item.id)
            } catch {
                // Anything else is worth another go later, up to a limit.
                _ = try? await queue.recordFailure(item.id)
                // Stop on the first genuine failure: the connection is probably
                // gone, and hammering the rest achieves nothing.
                break
            }
        }
        return sent
    }

    private func send(_ item: MutationQueue.Pending) async throws {
        switch item.kind {
        case .position:
            let payload = try JSONDecoder().decode(PositionPayload.self, from: item.payload)
            try await client.post(Endpoint.positions(item.bookUUID), body: payload)
        case .status:
            let payload = try JSONDecoder().decode(StatusPayload.self, from: item.payload)
            try await client.put(Endpoint.status(item.bookUUID), body: payload)
        case .rating:
            let payload = try JSONDecoder().decode(RatingPayload.self, from: item.payload)
            if let rating = payload.rating {
                try await client.put(
                    Endpoint.rating(item.bookUUID),
                    body: LibraryMutationService.Rating(rating: rating),
                )
            } else {
                try await client.delete(Endpoint.rating(item.bookUUID))
            }
        }
    }
}
